import Cocoa
import Carbon
import Vision

// MARK: - Protocol

protocol TextCaptureStrategy {
    /// Attempt to capture selected text; returns nil if this strategy cannot fulfill.
    func tryCapture() -> String?
}

// MARK: - Strategy 1: Simulated Cmd+C (clipboard)

struct ClipboardCaptureStrategy: TextCaptureStrategy {
    func tryCapture() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let pb = NSPasteboard.general
        let initialCount = pb.changeCount
        let savedStrings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String]

        defer {
            let currentCount = pb.changeCount
            if currentCount == initialCount + 1 {
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
        down.flags = .maskCommand
        up.flags   = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        var captured: String?
        for _ in 0..<40 {
            if pb.changeCount != initialCount {
                captured = pb.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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
              CFGetTypeID(appRef) == AXUIElementGetTypeID()
        else { return nil }
        let app = appRef as! AXUIElement
        guard let elemRef = app.copyAttribute(kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(elemRef) == AXUIElementGetTypeID()
        else { return nil }
        let elem = elemRef as! AXUIElement
        guard let s = elem.copyAttribute(kAXSelectedTextAttribute as CFString) as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return s
    }
}

// MARK: - Strategy 3: Vision OCR (screen capture)

@available(macOS, deprecated: 14.0)
struct VisionOCRCaptureStrategy: TextCaptureStrategy {
    func tryCapture() -> String? {
        return autoreleasepool {
            let mouse = NSEvent.mouseLocation

            let passes: [(width: CGFloat, height: CGFloat, minConfidence: Float)] = [
                (240, 50,  0.35),
                (400, 90,  0.25),
                (560, 140, 0.15),
            ]

            for (w, h, minConf) in passes {
                let rect = CGRect(
                    x: mouse.x - w / 2,
                    y: mouse.y - h / 2,
                    width: w, height: h
                )
                guard let cgImage = CGWindowListCreateImage(
                    rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
                ) else { continue }

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                var observations: [VNRecognizedTextObservation]?
                ocrQueue.sync {
                    do {
                        try handler.perform([sharedOCRRequest])
                        observations = sharedOCRRequest.results
                    } catch {
                        observations = nil
                    }
                }
                guard let observations = observations, !observations.isEmpty else { continue }

                let filtered = observations
                    .compactMap { obs -> (text: String, y: Float, x: Float, width: Float)? in
                        guard let candidate = obs.topCandidates(1).first,
                              candidate.confidence >= minConf else { return nil }
                        let text = candidate.string
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        let bb = obs.boundingBox
                        return (text, Float(bb.origin.y), Float(bb.origin.x), Float(bb.width))
                    }
                    .sorted { a, b in
                        if abs(a.y - b.y) > 0.03 { return a.y > b.y }
                        return a.x < b.x
                    }

                guard !filtered.isEmpty else { continue }

                var deduped: [String] = []
                var prev = ""
                for item in filtered {
                    if item.text != prev { deduped.append(item.text) }
                    prev = item.text
                }

                var result = ""
                var lastY: Float = -1
                for item in filtered {
                    if lastY >= 0, abs(item.y - lastY) > 0.03 {
                        result += "\n"
                    }
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
}

// MARK: - AX convenience

private extension AXUIElement {
    func copyAttribute(_ attr: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attr, &value) == .success else { return nil }
        return value
    }
}
