import Cocoa
import Carbon
import Vision

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

// MARK: - Strategy 3: Vision OCR (local instance, no global singleton)

@available(macOS, deprecated: 14.0)
struct VisionOCRCaptureStrategy: TextCaptureStrategy {
    func tryCapture() -> String? {
        return autoreleasepool {
            let mouse = NSEvent.mouseLocation
            // NSEvent.mouseLocation uses AppKit coords (bottom-left origin),
            // but CGWindowListCreateImage expects CG coords (top-left origin).
            // Convert the mouse Y to the CG coordinate system.
            let cgScreenHeight = NSScreen.screens.map { $0.frame.maxY }.max()
                ?? NSScreen.main?.frame.maxY
                ?? 0
            let cgMouseY = cgScreenHeight - mouse.y

            let passes: [(width: CGFloat, height: CGFloat, minConfidence: Float)] = [
                (240, 50,  0.35), (400, 90, 0.25), (560, 140, 0.15),
            ]
            for (w, h, minConf) in passes {
                let rect = CGRect(x: mouse.x - w/2, y: cgMouseY - h/2, width: w, height: h)
                guard let rawCGImage = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
                else { continue }

                // Convert to pure grayscale to cut memory 75% and break IOSurface snapshot chain
                let grayImage = Self.toGrayscale(rawCGImage)
                guard let cgImage = grayImage else { continue }

                // Local request — destroyed when this loop iteration or function ends
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans","zh-Hant","en","ja","ko","fr","de","es"]
                request.minimumTextHeight = 0.02

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
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

                var deduped: [String] = []
                var prev = ""
                for item in filtered { if item.text != prev { deduped.append(item.text) }; prev = item.text }

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

    /// Convert CGImage to 8-bit grayscale to cut memory ~75% and break IOSurface snapshot chain
    private static func toGrayscale(_ image: CGImage) -> CGImage? {
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

// MARK: - AX convenience

private extension AXUIElement {
    func copyAttribute(_ attr: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attr, &value) == .success else { return nil }
        return value
    }
}
