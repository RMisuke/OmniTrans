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
    private var _overlayWindowID: Int32 = 0

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
        w.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.ignoresMouseEvents = false
        w.makeKeyAndOrderFront(nil)
        w.contentView = view

        overlayView = view
        window = w
        // Store window number for capture exclusion
        _overlayWindowID = Int32(w.windowNumber)
    }

    private func captureRegion(_ viewRect: CGRect) {
        guard viewRect.width > 20, viewRect.height > 10 else {
            dismiss()
            onComplete?(nil)
            onComplete = nil
            return
        }

        // Convert from AppKit view coords (bottom-left origin) to CG screen coords (top-left origin).
        // View coords are relative to the overlay window which is at screenFrame.origin.
        let appKitX = screenFrame.origin.x + viewRect.origin.x
        let appKitY = screenFrame.origin.y + viewRect.origin.y
        let w = viewRect.width
        let h = viewRect.height

        // Total screen space height for the CG coordinate flip
        let cgScreenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? screenFrame.maxY
        let cgY = cgScreenHeight - (appKitY + h)

        let captureRect = CGRect(x: appKitX, y: cgY, width: w, height: h)

        // Capture screen region excluding our own overlay window
        let image = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenBelowWindow,
            CGWindowID(_overlayWindowID),
            .bestResolution
        )
        // Fallback: if window-level exclusion fails, try generic capture
        let cgImage = image ?? CGWindowListCreateImage(
            captureRect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
        )
        guard let cgImage else {
            onComplete?(nil)
            onComplete = nil
            return
        }

        // OCR
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es"]
        request.minimumTextHeight = 0.01

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            onComplete?(nil)
            onComplete = nil
            return
        }

        guard let observations = request.results, !observations.isEmpty else {
            onComplete?(nil)
            onComplete = nil
            return
        }

        // Sort spatially: top→bottom first, then left→right within each row.
        // VNRecognizedTextObservation.boundingBox uses normalized coords (0,0 bottom-left, 1,1 top-right).
        // Normalized Y is bottom-to-top, so higher y = higher on screen = top row.
        let ordered = observations
            .compactMap { obs -> (text: String, y: Float, x: Float)? in
                guard let text = obs.topCandidates(1).first?.string
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                let bb = obs.boundingBox
                return (text, Float(bb.origin.y), Float(bb.origin.x))
            }
            .sorted { a, b in
                // Group by Y (tolerance 0.02 in normalized coords) → same visual row
                if abs(a.y - b.y) > 0.02 { return a.y > b.y }   // top first
                return a.x < b.x                                  // left to right
            }

        guard !ordered.isEmpty else {
            onComplete?(nil)
            onComplete = nil
            return
        }

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
        onComplete?(trimmed.isEmpty ? nil : trimmed)
        onComplete = nil
        dismiss()
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        overlayView = nil
    }
}

// MARK: - Overlay NSView (handles drag drawing)

private final class OverlayView: NSView {
    private var startPoint: NSPoint?
    private var currentRect: CGRect?
    private let onSelect: (CGRect) -> Void

    private let dimColor = NSColor.black.withAlphaComponent(0.3)
    private let borderColor = NSColor.systemBlue.withAlphaComponent(0.8)
    private let fillColor = NSColor.systemBlue.withAlphaComponent(0.1)

    init(onSelect: @escaping (CGRect) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let loc = convert(event.locationInWindow, from: nil)

        let minX = min(start.x, loc.x)
        let minY = min(start.y, loc.y)
        let w = abs(loc.x - start.x)
        let h = abs(loc.y - start.y)

        currentRect = CGRect(x: minX, y: minY, width: w, height: h)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint else { return }
        let loc = convert(event.locationInWindow, from: nil)

        let minX = min(start.x, loc.x)
        let minY = min(start.y, loc.y)
        let w = abs(loc.x - start.x)
        let h = abs(loc.y - start.y)

        // Pass view-local rect directly; coordinate conversion is done in captureRegion
        onSelect(CGRect(x: minX, y: minY, width: w, height: h))

        startPoint = nil
        currentRect = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 {
            onSelect(.zero)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        dimColor.setFill()
        dirtyRect.fill()

        guard let rect = currentRect, rect.width > 2, rect.height > 2 else { return }

        NSColor.clear.setFill()
        rect.fill()

        borderColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()

        fillColor.setFill()
        rect.fill()

        let label = "\(Int(rect.width))×\(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        let labelX = rect.minX + 4
        let labelY = rect.maxY - size.height - 4
        if labelY > rect.minY {
            label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)
        }
    }
}
