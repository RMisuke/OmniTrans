import Cocoa
import Carbon
@preconcurrency import Vision
@preconcurrency import CoreVideo
import os
import DisplayGeometry

extension Notification.Name {
    /// Posted when the SCStream screen capture fails (e.g. missing Screen
    /// Recording permission, display disconnected).
    static let omniTransOCRCaptureFailed = Notification.Name("OmniTransOCRCaptureFailed")
    /// Posted when screen capture succeeds but Vision OCR finds no text
    /// (e.g. blank region, unsupported script, or too-low contrast).
    static let omniTransOCRNoTextFound = Notification.Name("OmniTransOCRNoTextFound")
    /// Posted when OCR processing begins — triggers status bar "OCR识别中..." indicator.
    static let omniTransOCRLoading = Notification.Name("OmniTransOCRLoading")
    /// Posted when OCR completes (or fails) — dismisses the loading indicator.
    static let omniTransOCRDone = Notification.Name("OmniTransOCRDone")
}

// MARK: - OCR 结果模型

/// OCR 识别出的一行文字及其在屏幕上的区域。
struct OCRLineResult: Sendable {
    let text: String
    let confidence: Float
    /// 该行在屏幕上的区域（**AppKit 全局坐标**，bottom-left origin）。
    /// 由 Vision 归一化 boundingBox 经 `DisplayGeometry` 映射而来，
    /// 供原位替换/区域定位使用。
    let appKitFrame: CGRect
}

/// 一次 OCR 的完整结果：拼接文本 + 每行文字的区域坐标。
struct OCRResult: Sendable {
    let text: String
    let lines: [OCRLineResult]
}

/// Full-screen transparent overlay for drag-to-select OCR capture.
/// Activated by Opt+F hotkey — user drags a rectangle, OCR runs on release.
@MainActor
final class OCRSelectionOverlay {
    static let shared = OCRSelectionOverlay()

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "OCRSelection")

    private var window: NSWindow?
    private var overlayView: OverlayView?
    private var onComplete: ((OCRResult?) -> Void)?
    /// AppKit screen rect where the overlay was placed, for coordinate conversion
    private var screenFrame: CGRect = .zero
    private var _overlayWindowID: CGWindowID = 0
    /// Capture service — runtime-dispatched between SCK (macOS 15+) and CGWindowList (macOS 14).
    private let captureService: CaptureServiceProtocol = CaptureServiceFactory.makeService()
    /// C: 代际守卫 —— 防止连续触发导致旧 OCR 结果串给新回调（方案 C）。
    private let generationGuard = OCRGenerationGuard()

    private init() {}

    /// Show overlay and call completion with OCR'd text (nil if cancelled)
    func beginCapture(completion: @escaping (OCRResult?) -> Void) {
        guard window == nil else { return }
        // C: 新一轮 OCR 接管 —— 旧代际的结果将被丢弃（方案 C）
        generationGuard.next()
        onComplete = completion

        // 屏幕选择统一走 DisplayGeometry（AppKit 坐标匹配 NSScreen.frame），
        // 不依赖 NSScreen.main —— 确保 overlay 出现在鼠标所在的外接屏上。
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = DisplayGeometry.screen(containing: mouseLocation)
                ?? DisplayGeometry.nearestScreen(to: mouseLocation) else {
            completion(nil)
            return
        }
        screenFrame = screen.frame

        let view = OverlayView { [weak self] rect in
            self?.captureRegion(rect)
        }

        let w = KeyableBorderlessWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.12)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.ignoresMouseEvents = false
        w.makeKeyAndOrderFront(nil)
        w.contentView = view

        overlayView = view
        window = w
        // Store window number for capture exclusion
        _overlayWindowID = CGWindowID(w.windowNumber)
    }

    private func captureRegion(_ viewRect: CGRect) {
        guard viewRect.width > 20, viewRect.height > 10 else {
            dismiss()
            onComplete?(nil)
            onComplete = nil
            return
        }

        // Compute the selected region in AppKit screen coordinates (bottom-left origin).
        // We keep everything in AppKit coords and convert to image-pixel coords
        // inside scCapture using the actual captured image dimensions.
        let appKitRect = CGRect(
            x: screenFrame.origin.x + viewRect.origin.x,
            y: screenFrame.origin.y + viewRect.origin.y,
            width: viewRect.width,
            height: viewRect.height
        )

        let windowID = _overlayWindowID
        // C: 记录本次 OCR 的代际号，回调时校验，避免过期结果串台（方案 C）
        let generation = generationGuard.current

        // ═══ Immediate dismiss: remove gray overlay before OCR starts ═══
        // The SCContentFilter already excludes this window from the GPU
        // pixel stream (via excludingWindows:), so the capture is unaffected.
        dismiss()

        // Post "OCR识别中..." status bar indicator
        NotificationCenter.default.post(name: .omniTransOCRLoading, object: nil)

        // Task.detached avoids inheriting @MainActor isolation so that capture
        // + OCR run fully off the main thread.
        Task.detached { [captureService, weak self] in
            guard let self else { return }
            guard let pixelBuffer = await captureService.capture(appKitRect: appKitRect, excludingWindowID: windowID) else {
                os_log(.error, log: Self.log, "capture returned nil — appKitRect=%@ windowID=%u", NSStringFromRect(appKitRect), windowID)
                await MainActor.run {
                    // C: 若新一轮 OCR 已接管，丢弃本次（过期）结果（方案 C）
                    guard self.generationGuard.isValid(generation) else { return }
                    NotificationCenter.default.post(
                        name: .omniTransOCRCaptureFailed,
                        object: nil
                    )
                    // Ensure loading indicator is dismissed on failure
                    NotificationCenter.default.post(name: .omniTransOCRDone, object: nil)
                    self.onComplete?(nil)
                    self.onComplete = nil
                }
                return
            }

            let result = await self.performOCR(on: pixelBuffer, appKitRect: appKitRect)
            if let result {
                os_log(.debug, log: Self.log, "Vision result: \"%@\" bufferSize=%dx%d",
                       String(result.text.prefix(80)), CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
            } else {
                os_log(.debug, log: Self.log, "Vision result: nil bufferSize=%dx%d",
                       CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
            }
            await MainActor.run {
                // C: 若新一轮 OCR 已接管，丢弃本次（过期）结果（方案 C）
                guard self.generationGuard.isValid(generation) else { return }
                if result == nil {
                    NotificationCenter.default.post(
                        name: .omniTransOCRNoTextFound,
                        object: nil
                    )
                }
                self.onComplete?(result)
                self.onComplete = nil
                // DON'T dismiss here — overlay is already gone.
                // Post done notification; AppDelegate will dismiss the
                // loading indicator when it shows the floating panel.
            }
        }
    }

    // MARK: - OCR processing

    /// Primary recognition languages — English first since the user
    /// primarily works with English text.  Short list reduces model size.
    nonisolated private static let primaryLanguages  = ["en", "zh-Hans", "zh-Hant"]
    /// Secondary languages appended to provide broader script coverage.
    nonisolated private static let secondaryLanguages = ["ja", "ko"]

    /// Runs OCR with a multi-tier fallback chain.
    ///
    /// The hardware execution mode is determined by `OCRHardwareDiagnostic`
    /// at startup.  Depending on the result:
    ///   - `.ane`: `.accurate` + ANE (no timeout, fast)
    ///   - `.cpu`: `.accurate` + CPU (no timeout, slower but reliable)
    ///   - `.fast`: skip `.accurate` entirely, use `.fast` CRNN classifier
    ///
    /// ## Why timeout + fallback is needed
    /// On some macOS versions, Apple's TextRecognition E5 ANE model bundle
    /// for the host chip can be missing from the system framework (e.g. OTA
    /// update corruption).  The `OCRHardwareDiagnostic` probe detects this
    /// at startup and caches the result in `OCRHardwareMode.current` for the
    /// lifetime of the process.  Each launch re-evaluates the probe, so a
    /// future macOS update that restores the bundle is automatically detected.
    ///
    /// Declared `nonisolated` so Vision processing runs off the main actor,
    /// preventing UI stalls during neural-network inference.
    nonisolated private func performOCR(on pixelBuffer: CVPixelBuffer,
                                        appKitRect: CGRect) async -> OCRResult? {
            let bufW = CVPixelBufferGetWidth(pixelBuffer)
            let bufH = CVPixelBufferGetHeight(pixelBuffer)
            let mode = OCRHardwareMode.current

            // ── Attempt 1: .accurate (ANE or CPU, depending on probe) ──
            // If the startup probe determined that .accurate works on this
            // system (either with ANE or CPU fallback), give it unlimited
            // time — the probe has already confirmed it won't hang.
            // If probe determined .fast-only, skip with 0.3s fail-fast.
            let useAccurate = (mode != .fast)
            if useAccurate {
                if let result = await attemptOCR(pixelBuffer: pixelBuffer,
                                                 appKitRect: appKitRect,
                                                 level: .accurate,
                                                 languages: Self.primaryLanguages + Self.secondaryLanguages) {
                    return result
                }
                os_log(.debug, log: Self.log, ".accurate failed despite probe — falling through to .fast")
            }

            // ── Attempt 2: .fast + all languages (with language correction) ──
            if let result = await attemptOCR(pixelBuffer: pixelBuffer,
                                             appKitRect: appKitRect,
                                             level: .fast,
                                             languages: Self.primaryLanguages + Self.secondaryLanguages) {
                os_log(.error, log: Self.log, "Using fallback fast+all — language correction ON")
                return result
            }

            // ── Attempt 3: .fast + English only (with language correction) ──
            if let result = await attemptOCR(pixelBuffer: pixelBuffer,
                                             appKitRect: appKitRect,
                                             level: .fast,
                                             languages: ["en"]) {
                os_log(.error, log: Self.log, "Using fallback fast+en-only — language correction ON")
                return result
            }

            os_log(.error, log: Self.log, "All OCR attempts failed for buffer %dx%d", bufW, bufH)
            return nil
    }

    /// Run a single OCR attempt.
    ///
    /// `VNImageRequestHandler.perform()` is synchronous — it blocks the calling
    /// thread until Vision completes.  It is dispatched to a dedicated serial
    /// background queue so the calling Task (and the main actor) stay free.
    ///
    /// - Important: `.accurate` recognition is performed on raw pixel data
    ///   without any preprocessing — the neural network (Espresso CPU engine
    ///   when `VNDisableANE=1` is set in AppDelegate, or ANE otherwise) expects
    ///   natural image statistics.  Aggressive contrast or desaturation
    ///   preprocessing distorts features and harms accuracy.
    ///
    /// （审计：原 timeout 参数所有调用点均传 nil，为死代码路径，已移除。
    ///   硬件探测路径的超时门控保留在 OCRHardwareMode.swift 中。）
    nonisolated private func attemptOCR(
        pixelBuffer: CVPixelBuffer,
        appKitRect: CGRect,
        level: VNRequestTextRecognitionLevel,
        languages: [String]
    ) async -> OCRResult? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        // Language correction is enabled ONLY for .fast mode.
        // The .fast level uses a lightweight CRNN classifier that can produce
        // character-substitution errors; the statistical language model corrects
        // these at the cost of extra CPU post-processing time.  .accurate uses
        // a full neural network and does not need correction.
        request.usesLanguageCorrection = (level == .fast)
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0.005

        // 专用串行队列执行同步的 Vision perform，避免并发 .accurate 堆积。
        // CVBuffer 非 Sendable：用显式 Sendable 盒声明「后台执行期间生命周期由调用方保证」。
        let queue = DispatchQueue(label: "ocr-queue")
        let pb = PixelBufferBox(pixelBuffer)

        return await withCheckedContinuation { continuation in
            queue.async {
                let handler = VNImageRequestHandler(cvPixelBuffer: pb.value, options: [:])
                do {
                    try handler.perform([request])
                    let text = Self.buildResult(from: request.results,
                                                appKitRect: appKitRect,
                                                minConfidence: 0.2,
                                                rowThreshold: 0.02)
                    continuation.resume(returning: text)
                } catch {
                    os_log(.error, log: Self.log, "Vision perform failed: %@", error.localizedDescription)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 从 `VNRecognizedTextObservation` 构建 `OCRResult`：文字行按空间顺序
    /// （上→下、左→右）排序拼接，并把每行的归一化 boundingBox 映射回屏幕
    /// **AppKit 全局坐标**（bottom-left）。
    ///
    /// - Parameters:
    ///   - observations: Vision 识别结果。
    ///   - appKitRect: 捕获时使用的 AppKit 全局区域（bottom-left）；归一化
    ///     坐标经 `DisplayGeometry` 映射回屏幕。
    ///   - rowThreshold: 归一化行高阈值（相对整幅捕获图），用于行分组。
    nonisolated private static func buildResult(
        from observations: [VNRecognizedTextObservation]?,
        appKitRect: CGRect,
        minConfidence: Float,
        rowThreshold: CGFloat
    ) -> OCRResult? {
        guard let observations, !observations.isEmpty else { return nil }

        let lines = observations.compactMap { obs -> OCRLineResult? in
            guard let candidate = obs.topCandidates(1).first,
                  candidate.confidence >= minConfidence
            else { return nil }
            let t = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let frame = DisplayGeometry.appKitGlobalRect(fromVisionNormalized: obs.boundingBox,
                                                         within: appKitRect)
            return OCRLineResult(text: t, confidence: candidate.confidence, appKitFrame: frame)
        }
        guard !lines.isEmpty else { return nil }

        // 空间排序：行（Y 相差超过阈值）按 Y 从大到小（屏幕上方优先），
        // 同行按 X 从小到大。
        let ordered = lines.sorted { a, b in
            if abs(a.appKitFrame.minY - b.appKitFrame.minY) > rowThreshold * appKitRect.height {
                return a.appKitFrame.minY > b.appKitFrame.minY
            }
            return a.appKitFrame.minX < b.appKitFrame.minX
        }

        var result = ""
        var lastY: CGFloat = .greatestFiniteMagnitude
        var prevText = ""
        for item in ordered {
            if item.text == prevText { continue }
            prevText = item.text
            if lastY != .greatestFiniteMagnitude,
               abs(item.appKitFrame.minY - lastY) > rowThreshold * appKitRect.height {
                result += "\n"
            } else if !result.isEmpty {
                result += " "
            }
            result += item.text
            lastY = item.appKitFrame.minY
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OCRResult(text: trimmed, lines: ordered)
    }

    private func dismiss() {
        window?.alphaValue = 0
        window?.orderOut(nil)
        window = nil
        overlayView = nil
        // Aggressively reclaim Vision ANE / GPU resident memory.
        // （审计：原实现在主队列与后台队列各调度一次 purge，后台那次又 hop 回
        //   MainActor，实际执行两次全量清理；现在只保留一次，且延迟到下一
        //   runloop 避免拖慢 OCR 结果弹窗的首帧。）
        DispatchQueue.main.async {
            MemoryPurgeHelper.shared.purgeBackendCache()
        }
    }
}

// MARK: - Borderless Key Window

/// `.borderless` 窗口默认 `canBecomeKey == false`，导致 overlay 永远无法成为
/// key window、`keyDown`（ESC 取消）收不到事件。子类化重写为 `true`
/// 以保证 ESC 可取消框选（审计 B1）。
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay NSView (handles drag drawing)

/// Overlay NSView that uses CAShapeLayer for selection-rectangle drawing.
/// The dim background is set via the layer's backgroundColor; during drag,
/// only the CAShapeLayer path is updated — no needsDisplay / draw(_:) calls,
/// eliminating main-thread redraw overhead on every mouseDragged event.
private final class OverlayView: NSView {
    private var startPoint: NSPoint?
    private var currentRect: CGRect?
    private let onSelect: (CGRect) -> Void

    /// CAShapeLayer for the selection rectangle with hole-punch effect.
    /// Uses even-odd fill rule: outer path = full bounds, inner path = selection rect.
    private let selectionLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = NSColor.systemBlue.withAlphaComponent(0.1).cgColor
        l.strokeColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        l.lineWidth = 2
        l.fillRule = .evenOdd
        l.isHidden = true
        return l
    }()

    /// CATextLayer for the live size label (e.g. "320×180").
    private let sizeLabel: CATextLayer = {
        let l = CATextLayer()
        l.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        l.fontSize = 11
        l.foregroundColor = NSColor.white.cgColor
        l.alignmentMode = .left
        l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        l.isHidden = true
        return l
    }()

    init(onSelect: @escaping (CGRect) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        layer?.addSublayer(selectionLayer)
        layer?.addSublayer(sizeLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        selectionLayer.isHidden = true
        sizeLabel.isHidden = true
        // Enable rasterization during drag so the CAShapeLayer hole-punch
        // is cached as a bitmap — avoids expensive full-screen re-compositing
        // on every mouseDragged event at 5K resolution.
        layer?.shouldRasterize = true
        layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0
        // 尺寸 label 的 contentsScale 跟随 overlay 所在屏（外接屏可能与
        // 主屏缩放率不同），避免文字模糊。
        if let window { sizeLabel.contentsScale = window.backingScaleFactor }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let loc = convert(event.locationInWindow, from: nil)
        updateSelection(start: start, loc: loc)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint else { return }
        let loc = convert(event.locationInWindow, from: nil)
        updateSelection(start: start, loc: loc)

        let minX = min(start.x, loc.x)
        let minY = min(start.y, loc.y)
        let w = abs(loc.x - start.x)
        let h = abs(loc.y - start.y)

        // Disable rasterization now that dragging is done; the bitmap cache
        // is no longer needed and would waste VRAM.
        layer?.shouldRasterize = false

        // Pass view-local rect directly; coordinate conversion is done in captureRegion
        onSelect(CGRect(x: minX, y: minY, width: w, height: h))

        startPoint = nil
        currentRect = nil
        selectionLayer.isHidden = true
        sizeLabel.isHidden = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 {
            onSelect(.zero)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Selection layer update (no needsDisplay — direct CAShapeLayer manipulation)

    private func updateSelection(start: NSPoint, loc: NSPoint) {
        let minX = min(start.x, loc.x)
        let minY = min(start.y, loc.y)
        let w = abs(loc.x - start.x)
        let h = abs(loc.y - start.y)

        guard w > 2, h > 2 else {
            selectionLayer.isHidden = true
            sizeLabel.isHidden = true
            return
        }

        let rect = CGRect(x: minX, y: minY, width: w, height: h)
        currentRect = rect

        // Hole-punch path: full bounds (filled) + selection rect (unfilled via even-odd)
        let fullPath = CGMutablePath()
        fullPath.addRect(bounds)
        fullPath.addRect(rect)
        selectionLayer.path = fullPath
        selectionLayer.isHidden = false

        // Live size label via CATextLayer (no draw call)
        let label = "\(Int(w))×\(Int(h))"
        sizeLabel.string = label
        let labelW: CGFloat = label.size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ]).width
        let labelX = rect.minX + 4
        let labelY = rect.maxY - 18
        sizeLabel.frame = CGRect(x: labelX, y: labelY, width: labelW + 8, height: 18)
        sizeLabel.isHidden = labelY <= rect.minY
    }
}

// MARK: - CVBuffer Sendable Box

/// CVBuffer（`CVPixelBuffer`）非 Sendable 的显式包装：由调用方保证在后台
/// 队列执行期间缓冲区生命周期有效（消除 `@Sendable` 闭包捕获告警）。
private final class PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}
