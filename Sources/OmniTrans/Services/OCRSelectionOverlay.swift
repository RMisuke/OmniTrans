import Cocoa
import Carbon
import Vision

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
@MainActor
final class OCRSelectionOverlay {
    static let shared = OCRSelectionOverlay()

    private var window: NSWindow?
    private var overlayView: OverlayView?
    private var onComplete: ((String?) -> Void)?
    /// AppKit screen rect where the overlay was placed, for coordinate conversion
    private var screenFrame: CGRect = .zero
    private var _overlayWindowID: CGWindowID = 0
    /// Capture service — runtime-dispatched between SCK (macOS 15+) and CGWindowList (macOS 14).
    private let captureService: CaptureServiceProtocol = CaptureServiceFactory.makeService()

    private init() {}

    /// Show overlay and call completion with OCR'd text (nil if cancelled)
    func beginCapture(completion: @escaping (String?) -> Void) {
        guard window == nil else { return }
        onComplete = completion

        // Use the screen containing the mouse cursor — not NSScreen.main —
        // so the overlay always appears on the correct display in multi-
        // monitor setups (especially when the external monitor isn't the
        // "main" screen).
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
                ?? NSScreen.main else {
            completion(nil)
            return
        }
        screenFrame = screen.frame

        let view = OverlayView { [weak self] rect in
            self?.captureRegion(rect)
        }

        let w = NSWindow(
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
                print("[OCR] ❌ capture returned nil — appKitRect=\(appKitRect) windowID=\(windowID)")
                await MainActor.run {
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

            let text = self.performOCR(on: pixelBuffer)
            print("[OCR] Vision result: \(text != nil ? "\"\(text!.prefix(80))\"" : "nil") — bufferSize=\(CVPixelBufferGetWidth(pixelBuffer))×\(CVPixelBufferGetHeight(pixelBuffer))")
            await MainActor.run {
                if text == nil {
                    NotificationCenter.default.post(
                        name: .omniTransOCRNoTextFound,
                        object: nil
                    )
                }
                self.onComplete?(text)
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
    nonisolated private func performOCR(on pixelBuffer: CVPixelBuffer) -> String? {
        return autoreleasepool { () -> String? in
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
                if let text = attemptOCR(pixelBuffer: pixelBuffer,
                                         level: .accurate,
                                         languages: Self.primaryLanguages + Self.secondaryLanguages,
                                         label: "accurate+all",
                                         timeout: nil) {
                    return text
                }
                print("[OCR] ⚠️ .accurate failed despite probe — falling through to .fast")
            }

            // ── Attempt 2: .fast + all languages (with language correction) ──
            if let text = attemptOCR(pixelBuffer: pixelBuffer,
                                     level: .fast,
                                     languages: Self.primaryLanguages + Self.secondaryLanguages,
                                     label: "fast+all",
                                     timeout: nil) {
                print("[OCR] ⚠️ Using fallback fast+all — language correction ON")
                return text
            }

            // ── Attempt 3: .fast + English only (with language correction) ──
            if let text = attemptOCR(pixelBuffer: pixelBuffer,
                                     level: .fast,
                                     languages: ["en"],
                                     label: "fast+en-only",
                                     timeout: nil) {
                print("[OCR] ⚠️ Using fallback fast+en-only — language correction ON")
                return text
            }

            print("[OCR] ❌ All OCR attempts failed for buffer \(bufW)×\(bufH)")
            return nil
        }
    }

    /// Run a single OCR attempt, optionally with a timeout.
    ///
    /// `VNImageRequestHandler.perform()` is synchronous — it blocks the calling
    /// thread until Vision completes.  When `.accurate` triggers ANE model
    /// compilation that hangs, we cannot cancel it via Swift concurrency.
    /// Instead, we dispatch it to a dedicated background queue and use a
    /// `DispatchSemaphore` with a timeout to unblock the caller.
    ///
    /// - Important: `.accurate` recognition is performed on raw pixel data
    ///   without any preprocessing — the neural network (Espresso CPU engine
    ///   when `VNDisableANE=1` is set in AppDelegate, or ANE otherwise) expects
    ///   natural image statistics.  Aggressive contrast or desaturation
    ///   preprocessing distorts features and harms accuracy.
    ///
    /// - Parameter timeout: Seconds to wait before giving up.  `nil` = no timeout.
    nonisolated private func attemptOCR(
        pixelBuffer: CVPixelBuffer,
        level: VNRequestTextRecognitionLevel,
        languages: [String],
        label: String,
        timeout: Double?
    ) -> String? {
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

        // Use a dedicated serial queue so concurrent `.accurate` attempts
        // don't pile up on the global concurrent queue.
        let queue = DispatchQueue(label: "ocr-\(label)")
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        queue.async {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[OCR] ⚠️ \(label) failed: \(error.localizedDescription)")
                semaphore.signal()
                return
            }

            let text = Self.extractOrderedText(from: request.results,
                                                minConfidence: 0.2,
                                                rowThreshold: 0.02)
            result = text
            semaphore.signal()
        }

        if let timeout {
            _ = semaphore.wait(timeout: .now() + timeout)
            if result == nil {
                print("[OCR] ⏱ \(label) timed out after \(timeout)s")
            }
        } else {
            semaphore.wait()
        }

        return result
    }

    /// Extracts text from `VNRecognizedTextObservation` results sorted
    /// spatially (top→bottom, left→right) and joined with line breaks.
    nonisolated private static func extractOrderedText(
        from observations: [VNRecognizedTextObservation]?,
        minConfidence: Float,
        rowThreshold: Float
    ) -> String? {
        guard let observations, !observations.isEmpty else { return nil }

        let ordered = observations
            .compactMap { obs -> (text: String, y: Float, x: Float)? in
                guard let candidate = obs.topCandidates(1).first,
                      candidate.confidence >= minConfidence
                else { return nil }
                let t = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                let bb = obs.boundingBox
                return (t, Float(bb.origin.y), Float(bb.origin.x))
            }
            .sorted { a, b in
                if abs(a.y - b.y) > rowThreshold { return a.y > b.y }
                return a.x < b.x
            }

        guard !ordered.isEmpty else { return nil }

        var result = ""
        var lastY: Float = -1
        var prevText = ""
        for item in ordered {
            if item.text == prevText { continue }
            prevText = item.text
            if lastY >= 0, abs(item.y - lastY) > rowThreshold {
                result += "\n"
            } else if !result.isEmpty {
                result += " "
            }
            result += item.text
            lastY = item.y
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func dismiss() {
        window?.alphaValue = 0
        window?.orderOut(nil)
        window = nil
        overlayView = nil
        // Aggressively reclaim Vision ANE / GPU resident memory
        DispatchQueue.main.async {
            MemoryPurgeHelper.shared.purgeBackendCache()
        }
        // Also hint to the kernel on a background queue for deeper reclaim
        DispatchQueue.global(qos: .utility).async {
            Task { @MainActor in MemoryPurgeHelper.shared.purgeBackendCache() }
        }
    }
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
