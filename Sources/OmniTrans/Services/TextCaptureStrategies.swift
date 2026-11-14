import Cocoa
import Carbon
import os

// MARK: - Protocol

protocol TextCaptureStrategy {
    func tryCapture() -> String?
}

// MARK: - Strategy 1: Simulated Cmd+C

struct ClipboardCaptureStrategy: TextCaptureStrategy {
    func tryCapture() -> String? {
        guard AXIsProcessTrusted() else {
            #if DEBUG
            os_log(.debug, log: OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.omnitrans.app", category: "Permissions"),
                   "[Clipboard] AX permission denied — skipping capture")
            #endif
            return nil
        }
        let pb = NSPasteboard.general
        let initialCount = pb.changeCount
        // 全保真备份（审计 H10）：图片/文件等所有类型一并恢复。
        let snapshot = PasteboardSnapshot(pb)
        defer {
            // Restore clipboard if *any* change occurred — not just initialCount+1.
            // This handles the case where a third-party app also modifies the
            // pasteboard during the capture window (TOCTOU-safe snapshot compare).
            if pb.changeCount != initialCount {
                snapshot.restore(to: pb)
            }
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        else { return nil }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        var captured: String?
        for _ in 0..<30 {
            if pb.changeCount != initialCount {
                captured = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let c = captured, !c.isEmpty { break }
            }
            Thread.sleep(forTimeInterval: 0.003)
        }
        return captured
    }
}

// MARK: - Strategy 2: AX API direct read

/// Timeout (seconds) for AX API calls — prevents indefinite blocking when
/// the target application is unresponsive (e.g. beachballing).
private let kAXTimeout: Float = 0.5

struct AXCaptureStrategy: TextCaptureStrategy {
    func tryCapture() -> String? {
        guard AXIsProcessTrusted() else {
            #if DEBUG
            os_log(.debug, log: OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.omnitrans.app", category: "Permissions"),
                   "[AX] AX permission denied — skipping capture")
            #endif
            return nil
        }
        let system = AXUIElementCreateSystemWide()
        guard let appRef = system.copyAttribute(kAXFocusedApplicationAttribute as CFString),
              CFGetTypeID(appRef) == AXUIElementGetTypeID()
        else { return nil }
        let app = appRef as! AXUIElement
        AXUIElementSetMessagingTimeout(app, kAXTimeout)
        guard let elemRef = app.copyAttribute(kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(elemRef) == AXUIElementGetTypeID()
        else { return nil }
        let elem = elemRef as! AXUIElement
        AXUIElementSetMessagingTimeout(elem, kAXTimeout)
        guard let s = elem.copyAttribute(kAXSelectedTextAttribute as CFString) as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}// MARK: - Strategy 3: ScreenCaptureKit OCR（委托统一识别管线）

/// 鼠标附近区域 OCR 兜底策略 —— 划词链路（Clipboard → AX → OCR）的最后一级。
/// 捕获/预处理/竞速识别全部委托 `OCRCapturePipeline` 的同步桥接入口，
/// 本策略只负责「以鼠标为中心的多尺寸递增重试」。
struct ScreenCaptureOCRCaptureStrategy: TextCaptureStrategy {

    /// 以鼠标为中心的候选区域尺寸序列 —— 从小到大递增：
    /// 小区域快且噪声少；失败则扩大范围重试。
    private static let passes: [(width: CGFloat, height: CGFloat)] = [
        (240, 50), (400, 90), (560, 140),
    ]

    /// 单次尝试的超时上限（秒）。小区域竞速识别通常亚秒级完成。
    private static let perPassTimeout: TimeInterval = 10

    func tryCapture() -> String? {
        // NSEvent.mouseLocation 是 AppKit 全局坐标（bottom-left）。
        // 保持 AppKit 坐标系，不做 CG 翻转 —— 与 NSScreen.frame 一致，
        // 外接屏在主屏任意方向时均正确。
        let mouse = NSEvent.mouseLocation

        for pass in Self.passes {
            let rect = CGRect(x: mouse.x - pass.width/2,
                              y: mouse.y - pass.height/2,
                              width: pass.width,
                              height: pass.height)
            guard let text = OCRCapturePipeline.captureAndRecognizeSync(
                appKitRect: rect,
                excludingWindowID: 0,
                timeout: Self.perPassTimeout)
            else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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
    /// Maximum context characters — derived from the user's intensity setting
    /// at capture time, avoiding over-capture when intensity is low.
    private static var maxContextChars: Int { ContextAwareService.contextCharLimit }

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
              CFGetTypeID(appRef) == AXUIElementGetTypeID()
        else { return nil }
        let app = appRef as! AXUIElement
        AXUIElementSetMessagingTimeout(app, kAXTimeout)

        guard let elemRef = app.copyAttribute(kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(elemRef) == AXUIElementGetTypeID()
        else { return nil }
        let elem = elemRef as! AXUIElement
        AXUIElementSetMessagingTimeout(elem, kAXTimeout)

        // ── Get current selection range ──
        guard let rangeVal = elem.copyAttribute(kAXSelectedTextRangeAttribute as CFString),
              CFGetTypeID(rangeVal) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &range) else { return nil }

        // ── Get total character count ──
        var totalChars: Int
        if let numVal = elem.copyAttribute(kAXNumberOfCharactersAttribute as CFString) as? NSNumber {
            totalChars = numVal.intValue
        } else if let numVal = elem.copyAttribute(kAXNumberOfCharactersAttribute as CFString),
                  CFGetTypeID(numVal) == AXValueGetTypeID() {
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
        // 扩选会破坏用户选区且键盘模拟无法精确还原 —— 先经 AX 记录原选区，
        // 退出时恢复；AX 不可用则跳过扩选（审计 H11）。
        guard let originalRange = Self.focusedSelectedTextRange() else { return nil }

        let pb = NSPasteboard.general
        let savedChangeCount = pb.changeCount
        let snapshot = PasteboardSnapshot(pb)

        // ── Restore clipboard and selection on exit ──
        defer {
            // Only restore if pasteboard was modified
            if pb.changeCount != savedChangeCount {
                snapshot.restore(to: pb)
            }
            Self.restoreFocusedSelectedTextRange(originalRange)
        }

        let src = CGEventSource(stateID: .hidSystemState)

        // ── Capture leading context (Cmd+Shift+LeftArrow → Cmd+C) ──
        let leading = captureSimulatedSide(src: src, direction: .left, timeoutSeconds: 0.04)
        // ── Minimal settle time before next expansion ──
        Thread.sleep(forTimeInterval: 0.003)
        // ── Capture trailing context (Cmd+Shift+RightArrow → Cmd+C) ──
        let trailing = captureSimulatedSide(src: src, direction: .right, timeoutSeconds: 0.04)

        guard !leading.isEmpty || !trailing.isEmpty else { return nil }

        return CapturedContext(
            selectedText: selectedText,
            leadingContext: String(leading.suffix(maxContextChars)),
            trailingContext: String(trailing.prefix(maxContextChars))
        )
    }

    private enum Direction { case left, right }

    // MARK: - AX 选区记录/恢复（审计 H11）

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let appRef = system.copyAttribute(kAXFocusedApplicationAttribute as CFString),
              CFGetTypeID(appRef) == AXUIElementGetTypeID() else { return nil }
        let app = appRef as! AXUIElement
        guard let elemRef = app.copyAttribute(kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(elemRef) == AXUIElementGetTypeID() else { return nil }
        return (elemRef as! AXUIElement)
    }

    private static func focusedSelectedTextRange() -> CFRange? {
        guard let elem = focusedElement(),
              let rangeVal = elem.copyAttribute(kAXSelectedTextRangeAttribute as CFString),
              CFGetTypeID(rangeVal) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func restoreFocusedSelectedTextRange(_ range: CFRange) {
        guard let elem = focusedElement() else { return }
        var r = range
        guard let value = AXValueCreate(.cfRange, &r) else { return }
        AXUIElementSetAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, value)
    }

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
        Thread.sleep(forTimeInterval: 0.005)

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
            Thread.sleep(forTimeInterval: 0.001)
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
