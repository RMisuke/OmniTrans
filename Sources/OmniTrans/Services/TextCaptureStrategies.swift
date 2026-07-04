import Cocoa
import Carbon
import Vision
import ScreenCaptureKit

// MARK: - Protocol

protocol TextCaptureStrategy {
    func tryCapture() -> String?
}

// MARK: - Strategy 1: Simulated Cmd+C

struct ClipboardCaptureStrategy: TextCaptureStrategy {
    func tryCapture() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pb = NSPasteboard.general
        let initialCount = pb.changeCount
        let savedStrings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String]
        defer {
            if pb.changeCount == initialCount + 1 {
                pb.clearContents()
                if let strings = savedStrings, !strings.isEmpty {
                    pb.setString(strings.joined(separator: "\n"), forType: .string)
                }
            }
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        else { return nil }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        var captured: String?
        for _ in 0..<40 {
            if pb.changeCount != initialCount {
                captured = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let c = captured, !c.isEmpty { break }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return captured
    }
}

// MARK: - Strategy 2: AX API direct read

struct AXCaptureStrategy: TextCaptureStrategy {
    func tryCapture() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let appRef = system.copyAttribute(kAXFocusedApplicationAttribute as CFString),
              CFGetTypeID(appRef) == AXUIElementGetTypeID() else { return nil }
        let app = appRef as! AXUIElement
        guard let elemRef = app.copyAttribute(kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(elemRef) == AXUIElementGetTypeID() else { return nil }
        let elem = elemRef as! AXUIElement
        guard let s = elem.copyAttribute(kAXSelectedTextAttribute as CFString) as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

// MARK: - Strategy 3: ScreenCaptureKit OCR (modern, non-deprecated)

/// Uses `SCScreenshotManager.captureImage` + `VNRecognizeTextRequest`
/// to perform regional OCR without any deprecated APIs.
struct ScreenCaptureOCRCaptureStrategy: TextCaptureStrategy {
    func tryCapture() -> String? {
        return autoreleasepool {
            let mouse = NSEvent.mouseLocation
            let cgScreenHeight = NSScreen.screens.map { $0.frame.maxY }.max()
                ?? NSScreen.main?.frame.maxY
                ?? 0
            let cgMouseY = cgScreenHeight - mouse.y

            let passes: [(width: CGFloat, height: CGFloat, minConfidence: Float)] = [
                (240, 50,  0.35), (400, 90, 0.25), (560, 140, 0.15),
            ]

            for (w, h, minConf) in passes {
                let rect = CGRect(x: mouse.x - w/2, y: cgMouseY - h/2, width: w, height: h)

                guard let cgImage = captureScreen(rect: rect) else { continue }

                // Convert to grayscale to cut memory ~75%
                let grayImage = toGrayscale(cgImage)
                guard let processedImage = grayImage else { continue }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["zh-Hans","zh-Hant","en","ja","ko","fr","de","es"]
                request.minimumTextHeight = 0.02

                let handler = VNImageRequestHandler(cgImage: processedImage, options: [:])
                var observations: [VNRecognizedTextObservation]?
                do {
                    try handler.perform([request])
                    observations = request.results
                } catch { continue }

                guard let observations, !observations.isEmpty else { continue }

                let filtered = observations
                    .compactMap { obs -> (text: String, y: Float, x: Float, width: Float)? in
                        guard let c = obs.topCandidates(1).first, c.confidence >= minConf else { return nil }
                        let t = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return nil }
                        let bb = obs.boundingBox
                        return (t, Float(bb.origin.y), Float(bb.origin.x), Float(bb.width))
                    }
                    .sorted { a, b in
                        if abs(a.y - b.y) > 0.03 { return a.y > b.y }
                        return a.x < b.x
                    }
                guard !filtered.isEmpty else { continue }

                var result = ""
                var lastY: Float = -1
                for item in filtered {
                    if lastY >= 0, abs(item.y - lastY) > 0.03 { result += "\n" }
                    if !result.isEmpty && result.last != "\n" { result += " " }
                    result += item.text
                    lastY = item.y
                }
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return nil
        }
    }

    // MARK: - Screen Capture (ScreenCaptureKit, non-deprecated)

    /// Captures a screen region using `SCScreenshotManager`.
    /// Uses a semaphore to bridge the async API into the synchronous
    /// `tryCapture()` interface required by the strategy protocol.
    private func captureScreen(rect: CGRect) -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: CGImage?

        Task {
            do {
                let content = try await SCShareableContent.current
                let midPoint = CGPoint(x: rect.midX, y: rect.midY)
                guard let display = content.displays.first(where: { $0.frame.contains(midPoint) })
                        ?? content.displays.first else {
                    semaphore.signal(); return
                }

                let displayOrigin = display.frame.origin
                let displayHeight  = display.frame.height

                let localX = rect.origin.x - displayOrigin.x
                let localY = rect.origin.y - displayOrigin.y
                let cgY = displayHeight - (localY + rect.height)
                let sourceRect = CGRect(
                    x: localX, y: cgY,
                    width: rect.width, height: rect.height
                )

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.sourceRect = sourceRect
                config.width  = Int(sourceRect.width)
                config.height = Int(sourceRect.height)

                result = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
            } catch {
                // Silent fail — fall through to next pass
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 0.5)
        return result
    }

    // MARK: - Grayscale conversion

    private func toGrayscale(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

// MARK: - Sliding-Window Context Capture

/// Captures up to 150 characters of text **before** and **after** the current
/// selection using the accessibility (AX) API.  Falls back to a keyboard-
/// simulation strategy when AX is unavailable (e.g. Electron / VS Code).
///
/// This runs synchronously on the calling thread and must complete within
/// ~50 ms to avoid blocking the hotkey response.
enum SlidingWindowContextCapture {

    /// Maximum characters captured on either side of the selection.
    /// This is the hard ceiling (500 chars at intensity 2); the actual
    /// capture radius is derived from `ContextAwareService.contextCharLimit`.
    private static let maxContextChars = 500

    /// Attempts to capture bidirectional context for `selectedText`.
    /// - Returns: `CapturedContext` with leading/trailing text, or `nil` if
    ///   capture fails or times out.
    static func capture(selectedText: String) -> CapturedContext? {
        guard AXIsProcessTrusted() else {
            // AX not available → try keyboard-simulation fallback
            return captureViaKeyboardSimulation(selectedText: selectedText)
        }
        // Try AX first
        if let ctx = captureViaAX(selectedText: selectedText) {
            return ctx
        }
        // AX failed → keyboard fallback
        return captureViaKeyboardSimulation(selectedText: selectedText)
    }

    // MARK: - Strategy A: AXUIElement Precision Capture

    private static func captureViaAX(selectedText: String) -> CapturedContext? {
        let system = AXUIElementCreateSystemWide()

        guard let appRef = system.copyAttribute(kAXFocusedApplicationAttribute as CFString),
              CFGetTypeID(appRef) == AXUIElementGetTypeID() else { return nil }
        let app = appRef as! AXUIElement

        guard let elemRef = app.copyAttribute(kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(elemRef) == AXUIElementGetTypeID() else { return nil }
        let elem = elemRef as! AXUIElement

        // ── Get current selection range ──
        guard let rangeVal = elem.copyAttribute(kAXSelectedTextRangeAttribute as CFString) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &range) else { return nil }

        // ── Get total character count ──
        var totalChars: Int
        if let numVal = elem.copyAttribute(kAXNumberOfCharactersAttribute as CFString) as? NSNumber {
            totalChars = numVal.intValue
        } else if let numVal = elem.copyAttribute(kAXNumberOfCharactersAttribute as CFString) {
            // Some apps return an AXValue wrapping the number
            var val: Int = 0
            if AXValueGetValue(numVal as! AXValue, .cfRange, &val) {
                totalChars = val
            } else {
                totalChars = 0
            }
        } else {
            totalChars = 0
        }
        // Fallback: try getting the full value string length
        if totalChars <= 0 {
            if let fullText = elem.copyAttribute(kAXValueAttribute as CFString) as? String {
                totalChars = fullText.count
            } else {
                return nil
            }
        }

        let selLocation = range.location
        let selLength = range.length
        guard selLocation >= 0, selLength > 0, totalChars > 0 else { return nil }

        // ── Leading context ──
        var leading = ""
        if selLocation > 0 {
            let leadStart = max(0, selLocation - maxContextChars)
            let leadLen = selLocation - leadStart
            var leadRange = CFRange(location: leadStart, length: leadLen)
            if let rangeValue = AXValueCreate(.cfRange, &leadRange) {
                var result: CFTypeRef?
                let err = AXUIElementCopyParameterizedAttributeValue(
                    elem, kAXStringForRangeParameterizedAttribute as CFString,
                    rangeValue, &result
                )
                if err == .success, let str = result as? String {
                    leading = String(str.suffix(maxContextChars))
                }
            }
        }

        // ── Trailing context ──
        var trailing = ""
        let trailStart = selLocation + selLength
        if trailStart < totalChars {
            let trailLen = min(totalChars - trailStart, maxContextChars)
            var trailRange = CFRange(location: trailStart, length: trailLen)
            if let rangeValue = AXValueCreate(.cfRange, &trailRange) {
                var result: CFTypeRef?
                let err = AXUIElementCopyParameterizedAttributeValue(
                    elem, kAXStringForRangeParameterizedAttribute as CFString,
                    rangeValue, &result
                )
                if err == .success, let str = result as? String {
                    trailing = String(str.prefix(maxContextChars))
                }
            }
        }

        // Return nil if no surrounding context was captured
        guard !leading.isEmpty || !trailing.isEmpty else { return nil }

        return CapturedContext(
            selectedText: selectedText,
            leadingContext: leading,
            trailingContext: trailing
        )
    }

    // MARK: - Strategy B: Keyboard Simulation Fallback

    /// When AX is unavailable (e.g. Electron apps), uses CGEvent keyboard
    /// simulation to expand the selection and copy surrounding text.
    ///
    /// **Safety guarantees**:
    /// - Clipboard is backed up and restored.
    /// - 0.05 s timeout prevents blocking the hotkey path.
    /// - Selection expansion uses `Cmd+Shift+LeftArrow` and `Cmd+Shift+RightArrow`
    ///   to select to line boundaries, then copies the result.
    private static func captureViaKeyboardSimulation(selectedText: String) -> CapturedContext? {
        let pb = NSPasteboard.general
        let savedChangeCount = pb.changeCount
        let savedItems = pb.readObjects(forClasses: [NSString.self], options: nil)

        // ── Restore clipboard on exit ──
        defer {
            // Only restore if pasteboard was modified
            if pb.changeCount != savedChangeCount {
                pb.clearContents()
                if let items = savedItems as? [String], !items.isEmpty {
                    pb.setString(items.joined(separator: "\n"), forType: .string)
                }
            }
        }

        let src = CGEventSource(stateID: .hidSystemState)

        // ── Capture leading context (Cmd+Shift+LeftArrow → Cmd+C) ──
        let leading = captureSimulatedSide(src: src, direction: .left, timeoutSeconds: 0.05)
        // ── Wait briefly for UI to settle ──
        Thread.sleep(forTimeInterval: 0.01)
        // ── Capture trailing context (Cmd+Shift+RightArrow → Cmd+C) ──
        let trailing = captureSimulatedSide(src: src, direction: .right, timeoutSeconds: 0.05)

        guard !leading.isEmpty || !trailing.isEmpty else { return nil }

        return CapturedContext(
            selectedText: selectedText,
            leadingContext: String(leading.suffix(maxContextChars)),
            trailingContext: String(trailing.prefix(maxContextChars))
        )
    }

    private enum Direction { case left, right }

    /// Simulates Cmd+Shift+{Left,Right}Arrow to select surrounding text,
    /// then Cmd+C to copy.  Returns the copied text (or "" on timeout).
    private static func captureSimulatedSide(
        src: CGEventSource?, direction: Direction, timeoutSeconds: Double
    ) -> String {
        let pb = NSPasteboard.general
        let initialCount = pb.changeCount

        let arrowKey: CGKeyCode = (direction == .left) ? 0x7B : 0x7C

        // Cmd+Shift+Arrow down
        guard let arrowDown = CGEvent(keyboardEventSource: src, virtualKey: arrowKey, keyDown: true) else { return "" }
        arrowDown.flags = [.maskCommand, .maskShift]
        arrowDown.post(tap: .cghidEventTap)

        // Cmd+Shift+Arrow up
        guard let arrowUp = CGEvent(keyboardEventSource: src, virtualKey: arrowKey, keyDown: false) else { return "" }
        arrowUp.flags = [.maskCommand, .maskShift]
        arrowUp.post(tap: .cghidEventTap)

        // Small delay to let OS process the selection change
        Thread.sleep(forTimeInterval: 0.01)

        // Cmd+C
        guard let copyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
              let copyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        else { return "" }
        copyDown.flags = .maskCommand; copyUp.flags = .maskCommand
        copyDown.post(tap: .cghidEventTap); copyUp.post(tap: .cghidEventTap)

        // ── Poll for pasteboard change with timeout ──
        let deadline = Date().timeIntervalSince1970 + timeoutSeconds
        var captured = ""
        while Date().timeIntervalSince1970 < deadline {
            if pb.changeCount != initialCount {
                captured = pb.string(forType: .string) ?? ""
                if !captured.isEmpty { break }
            }
            Thread.sleep(forTimeInterval: 0.002)
        }

        return captured
    }
}

// MARK: - AX convenience

private extension AXUIElement {
    func copyAttribute(_ attr: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attr, &value) == .success else { return nil }
        return value
    }
}
