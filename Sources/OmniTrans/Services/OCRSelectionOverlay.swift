import Cocoa
import Carbon
import CoreVideo
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

/// Full-screen transparent overlay for drag-to-select OCR capture.
/// Activated by Opt+F hotkey — user drags a rectangle, OCR runs on release.
///
/// ## 重构后的职责边界
/// 本类**只负责 UI**：框选窗口 / 遮罩绘制 / ESC 取消 / 代际守卫。
/// 「捕获 → 预处理 → 竞速识别 → 组装」全部委托给 `OCRCapturePipeline`
/// （见 `Sources/OmniTrans/OCR/`），本文件不再包含任何 Vision 调用。
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
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.ignoresMouseEvents = false
        // 先设置 contentView 再显示窗口：原实现先 orderFront 后设 contentView，
        // 首个 runloop 内视图 frame 未就绪，首次点击事件丢失（「点第二次才生效」根因之一）。
        w.contentView = view
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        // accessory 应用首击激活问题：确保 overlay 立即可接收点击（配合 acceptsFirstMouse）
        NSApp.activate(ignoringOtherApps: true)

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
        Task.detached { [weak self] in
            guard let self else { return }
            var pipeline = OCRCapturePipeline.shared
            do {
                let result = try await pipeline.captureAndRecognize(appKitRect: appKitRect,
                                                                    excludingWindowID: windowID)
                if let result {
                    os_log(.debug, log: Self.log, "Vision result: \"%@\"", String(result.text.prefix(80)))
                } else {
                    os_log(.debug, log: Self.log, "Vision result: nil (no text)")
                }
                await MainActor.run {
                    // C: 若新一轮 OCR 已接管，丢弃本次（过期）结果（方案 C）
                    guard self.generationGuard.isValid(generation) else { return }
                    if result == nil {
                        NotificationCenter.default.post(name: .omniTransOCRNoTextFound, object: nil)
                    }
                    self.onComplete?(result)
                    self.onComplete = nil
                    // DON'T dismiss here — overlay is already gone.
                    // Post done notification; AppDelegate will dismiss the
                    // loading indicator when it shows the floating panel.
                }
            } catch {
                os_log(.error, log: Self.log, "capture failed: %@", error.localizedDescription)
                await MainActor.run {
                    // C: 若新一轮 OCR 已接管，丢弃本次（过期）结果（方案 C）
                    guard self.generationGuard.isValid(generation) else { return }
                    NotificationCenter.default.post(name: .omniTransOCRCaptureFailed, object: nil)
                    // Ensure loading indicator is dismissed on failure
                    NotificationCenter.default.post(name: .omniTransOCRDone, object: nil)
                    self.onComplete?(nil)
                    self.onComplete = nil
                }
            }
        }
    }

    private func dismiss() {
        window?.alphaValue = 0
        window?.orderOut(nil)
        window = nil
        overlayView = nil
        // Aggressively reclaim Vision ANE / GPU resident memory.
        // 只调度一次清理，且延迟到下一 runloop 避免拖慢 OCR 结果弹窗的首帧。
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

    /// 灰色遮罩层：even-odd 路径（全屏外框 + 选区内框）—— 选区**外部**变暗，
    /// 内部完全透明以突出待捕获内容。
    private let dimMaskLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = NSColor.black.withAlphaComponent(0.15).cgColor
        l.fillRule = .evenOdd
        l.isHidden = true
        return l
    }()

    /// 蓝色边框层：仅描选区边线，内部填充透明。
    private let borderLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = NSColor.clear.cgColor
        l.strokeColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        l.lineWidth = 2
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
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(dimMaskLayer)
        layer?.addSublayer(borderLayer)
        layer?.addSublayer(sizeLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// accessory 应用窗口非 key 时首次点击默认被激活行为吞掉 ——
    /// 返回 true 让第一击直接进入框选（「点第二次才生效」根因之二）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        dimMaskLayer.isHidden = true
        borderLayer.isHidden = true
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
        dimMaskLayer.isHidden = true
        borderLayer.isHidden = true
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
            dimMaskLayer.isHidden = true
            borderLayer.isHidden = true
            sizeLabel.isHidden = true
            return
        }

        let rect = CGRect(x: minX, y: minY, width: w, height: h)
        currentRect = rect

        // 灰色遮罩：even-odd 挖孔 —— 外部变暗、内部透明
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        maskPath.addRect(rect)
        dimMaskLayer.path = maskPath
        dimMaskLayer.isHidden = false

        // 蓝色边框：仅选区轮廓，内部透明
        borderLayer.path = CGPath(rect: rect, transform: nil)
        borderLayer.isHidden = false

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
