import Cocoa
import Carbon
import Vision

/// Full-screen transparent overlay for drag-to-select OCR capture.
/// Activated by Opt+F hotkey — user drags a rectangle, OCR runs on release.
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

        guard let screen = NSScreen.main else {
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

        // ScreenCaptureKit: excludes overlay window in GPU, no .orderOut(nil) needed.
        // The overlay stays visible during capture — SCContentFilter erases it from
        // the pixel stream at the compositor level, eliminating the 50ms hide delay.
        Task {
            guard let cgImage = await captureService.capture(appKitRect: appKitRect, excludingWindowID: windowID) else {
                await MainActor.run {
                    onComplete?(nil)
                    onComplete = nil
                    dismiss()
                }
                return
            }

            let text = performOCR(on: cgImage)
            await MainActor.run {
                onComplete?(text)
                onComplete = nil
                dismiss()
            }
        }
    }

    // MARK: - OCR processing

    /// Runs VNRecognizeTextRequest on `cgImage`, returns ordered text.
    /// The input `cgImage` is consumed; caller should not retain it afterward.
    private func performOCR(on cgImage: CGImage) -> String? {
        // Use autoreleasepool to eagerly reclaim Vision's internal C++ buffers
        return autoreleasepool { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es"]
            request.minimumTextHeight = 0.01

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            guard let observations = request.results, !observations.isEmpty else { return nil }

            // Sort spatially: top→bottom first, then left→right within each row.
            let ordered = observations
                .compactMap { obs -> (text: String, y: Float, x: Float)? in
                    guard let text = obs.topCandidates(1).first?.string
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    let bb = obs.boundingBox
                    return (text, Float(bb.origin.y), Float(bb.origin.x))
                }
                .sorted { a, b in
                    if abs(a.y - b.y) > 0.02 { return a.y > b.y }
                    return a.x < b.x
                }

            guard !ordered.isEmpty else { return nil }

            // Deduplicate and join with line breaks between rows
            var result = ""
            var lastY: Float = -1
            var prevText = ""
            for item in ordered {
                if item.text == prevText { continue }
                prevText = item.text
                if lastY >= 0, abs(item.y - lastY) > 0.02 {
                    result += "\n"
                } else if !result.isEmpty {
                    result += " "
                }
                result += item.text
                lastY = item.y
            }

            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // Vision handler and request go out of scope here; autoreleasepool
            // ensures the backing CGImage / IOSurface / ANE buffers are released
            // before returning to the caller.
            return trimmed.isEmpty ? nil : trimmed
        }
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
            MemoryPurgeHelper.shared.purgeBackendCache()
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
