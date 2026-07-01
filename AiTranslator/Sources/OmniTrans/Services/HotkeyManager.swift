import Carbon
import Cocoa
import Vision

/// 划词取词: CGEvent 模拟 Cmd+C (需辅助功能权限) → AX fallback
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onHotkey: ((String?) -> Void)?

    // OCR capture hotkey (Opt+F by default)
    private var ocrHotkeyRef: EventHotKeyRef?
    private var ocrHandlerRef: EventHandlerRef?
    var onOCRHotkey: (() -> Void)?

    /// 当前是否拥有辅助功能权限
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Format a hotkey label from Carbon key/mod values e.g. "⌥D"
    static func hotkeyLabelFrom(carbonKey: Int, carbonMods: Int) -> String {
        let mods = UInt32(carbonMods)
        let key  = UInt32(carbonKey)
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyToString(UInt16(key))
        return s
    }

    /// 当前翻译快捷键的显示字符串 e.g. "⌥D"
    static func hotkeyLabel() -> String {
        let m = UserDefaults.standard.integer(forKey: "hotkey_carbonMods")
        let k = UserDefaults.standard.integer(forKey: "hotkey_carbonKey")
        let mods = m != 0 ? UInt32(m) : UInt32(optionKey)
        let key  = k != 0 ? UInt32(k) : UInt32(kVK_ANSI_D)
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyToString(UInt16(key))
        return s
    }

    /// 当前 OCR 框选快捷键的显示字符串 e.g. "⌥F"
    static func ocrHotkeyLabel() -> String {
        let m = UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonMods")
        let k = UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonKey")
        let mods = m != 0 ? UInt32(m) : UInt32(optionKey)
        let key  = k != 0 ? UInt32(k) : UInt32(kVK_ANSI_F)
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyToString(UInt16(key))
        return s
    }

    private static func keyToString(_ code: UInt16) -> String {
        switch code {
        case UInt16(kVK_ANSI_A): "A"; case UInt16(kVK_ANSI_D): "D"; case UInt16(kVK_ANSI_T): "T"
        case UInt16(kVK_ANSI_S): "S"; case UInt16(kVK_ANSI_W): "W"; case UInt16(kVK_ANSI_E): "E"
        case UInt16(kVK_ANSI_R): "R"; case UInt16(kVK_ANSI_F): "F"; case UInt16(kVK_ANSI_X): "X"
        case UInt16(kVK_ANSI_C): "C"; case UInt16(kVK_ANSI_V): "V"; case UInt16(kVK_ANSI_G): "G"
        case UInt16(kVK_ANSI_B): "B"; case UInt16(kVK_ANSI_H): "H"; case UInt16(kVK_ANSI_N): "N"
        case UInt16(kVK_ANSI_J): "J"; case UInt16(kVK_ANSI_M): "M"; case UInt16(kVK_ANSI_K): "K"
        case UInt16(kVK_ANSI_L): "L"; case UInt16(kVK_ANSI_O): "O"; case UInt16(kVK_ANSI_P): "P"
        case UInt16(kVK_ANSI_Q): "Q"; case UInt16(kVK_ANSI_U): "U"; case UInt16(kVK_ANSI_I): "I"
        case UInt16(kVK_ANSI_Y): "Y"; case UInt16(kVK_ANSI_Z): "Z"
        case UInt16(kVK_Space): "Space"
        case UInt16(kVK_ANSI_0): "0"; case UInt16(kVK_ANSI_1): "1"; case UInt16(kVK_ANSI_2): "2"
        case UInt16(kVK_ANSI_3): "3"; case UInt16(kVK_ANSI_4): "4"; case UInt16(kVK_ANSI_5): "5"
        case UInt16(kVK_ANSI_6): "6"; case UInt16(kVK_ANSI_7): "7"; case UInt16(kVK_ANSI_8): "8"
        case UInt16(kVK_ANSI_9): "9"
        case UInt16(kVK_ANSI_Minus): "-"; case UInt16(kVK_ANSI_Equal): "="
        case UInt16(kVK_ANSI_LeftBracket): "["; case UInt16(kVK_ANSI_RightBracket): "]"
        case UInt16(kVK_ANSI_Backslash): "\\"; case UInt16(kVK_ANSI_Semicolon): ";"
        case UInt16(kVK_ANSI_Quote): "'"; case UInt16(kVK_ANSI_Comma): ","
        case UInt16(kVK_ANSI_Period): "."; case UInt16(kVK_ANSI_Slash): "/"
        case UInt16(kVK_ANSI_Grave): "`"
        case UInt16(kVK_F1): "F1"; case UInt16(kVK_F2): "F2"; case UInt16(kVK_F3): "F3"
        case UInt16(kVK_F4): "F4"; case UInt16(kVK_F5): "F5"; case UInt16(kVK_F6): "F6"
        case UInt16(kVK_F7): "F7"; case UInt16(kVK_F8): "F8"; case UInt16(kVK_F9): "F9"
        case UInt16(kVK_F10): "F10"; case UInt16(kVK_F11): "F11"; case UInt16(kVK_F12): "F12"
        case UInt16(kVK_Return): "↩"; case UInt16(kVK_Tab): "⇥"
        case UInt16(kVK_Escape): "⎋"; case UInt16(kVK_Delete): "⌫"
        case UInt16(kVK_UpArrow): "↑"; case UInt16(kVK_DownArrow): "↓"
        case UInt16(kVK_LeftArrow): "←"; case UInt16(kVK_RightArrow): "→"
        default: keyCodeToStringViaSystem(UInt16(code)) ?? "?"
        }
    }

    /// Fallback using CGEvent to get the character for unknown key codes
    private static func keyCodeToStringViaSystem(_ keyCode: UInt16) -> String? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        else { return nil }
        var uniChars = [UniChar](repeating: 0, count: 4)
        var len = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &uniChars)
        if len > 0 {
            return String(utf16CodeUnits: uniChars, count: len).uppercased()
        }
        return nil
    }

    /// Convert NSEvent modifierFlags to Carbon modifier mask
    static func carbonMods(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    func register() {
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let m = UserDefaults.standard.integer(forKey: "hotkey_carbonMods")
        let k = UserDefaults.standard.integer(forKey: "hotkey_carbonKey")
        let mods = m != 0 ? UInt32(m) : UInt32(optionKey)
        let key  = k != 0 ? UInt32(k) : UInt32(kVK_ANSI_D)
        let hid = EventHotKeyID(signature: 0x4149544C, id: 1)
        RegisterEventHotKey(key, mods, hid, GetApplicationEventTarget(), 0, &hotkeyRef)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), unifiedHotkeyCallback, 1, &spec, ptr, &handlerRef)
    }

    func unregister() {
        if let r = hotkeyRef  { UnregisterEventHotKey(r); hotkeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }

    // MARK: - OCR hotkey (⌥F by default)

    func registerOCR() {
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let m = UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonMods")
        let k = UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonKey")
        let mods = m != 0 ? UInt32(m) : UInt32(optionKey)
        let key  = k != 0 ? UInt32(k) : UInt32(kVK_ANSI_F)
        let hid = EventHotKeyID(signature: 0x4149544C, id: 2)
        RegisterEventHotKey(key, mods, hid,
                            GetApplicationEventTarget(), 0, &ocrHotkeyRef)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), unifiedHotkeyCallback, 1,
                            &spec, ptr, &ocrHandlerRef)
    }

    /// Re-register OCR hotkey (called after user customization)
    func reregisterOCR(carbonKey: Int, carbonMods: Int) {
        unregisterOCR()
        UserDefaults.standard.set(carbonKey, forKey: "ocr_hotkey_carbonKey")
        UserDefaults.standard.set(carbonMods, forKey: "ocr_hotkey_carbonMods")
        registerOCR()
    }

    /// Reset OCR hotkey to default (Option+F)
    func resetOCRToDefault() {
        reregisterOCR(carbonKey: Int(kVK_ANSI_F), carbonMods: Int(optionKey))
    }

    func unregisterOCR() {
        if let r = ocrHotkeyRef  { UnregisterEventHotKey(r); ocrHotkeyRef = nil }
        if let h = ocrHandlerRef { RemoveEventHandler(h); ocrHandlerRef = nil }
    }

    /// Re-register hotkey with new key/mod values (called after user customization)
    func reregister(carbonKey: Int, carbonMods: Int) {
        unregister()
        UserDefaults.standard.set(carbonKey, forKey: "hotkey_carbonKey")
        UserDefaults.standard.set(carbonMods, forKey: "hotkey_carbonMods")
        register()
    }

    /// Reset hotkey to default (Option+D)
    func resetToDefault() {
        reregister(carbonKey: Int(kVK_ANSI_D), carbonMods: Int(optionKey))
    }

    // MARK: - Capture pipeline

    func capture() -> String? {
        // Channel 1: Simulated Cmd+C (primary, fastest)
        if Self.isTrusted, let text = captureViaSimulatedCopy() { return text }
        // Channel 2: AX API direct selection read
        if let ax = captureViaAX() { return ax }
        return nil
    }

    /// Translate-only capture — no OCR fallback (OCR is its own hotkey)
    func captureWithoutOCR() -> String? {
        return capture()
    }

    /// Full capture including OCR fallback (used internally for compatibility)
    func captureWithOCR() -> String? {
        if let text = capture() { return text }
        return captureViaVisionOCR()
    }

    /// Third channel: adaptive OCR capture — tries multiple capture sizes around mouse,
    /// orders text spatially (top→bottom, left→right), filters by confidence.
    @available(macOS, deprecated: 14.0, message: "CGWindowListCreateImage deprecated — ScreenCaptureKit preferred for future")
    private func captureViaVisionOCR() -> String? {
        return autoreleasepool {
            let mouse = NSEvent.mouseLocation

            // Adaptive sizes: tight → moderate → wide
            let passes: [(width: CGFloat, height: CGFloat, minConfidence: Float)] = [
                (240, 50,  0.35),   // pass 1: tight focus, high confidence
                (400, 90,  0.25),   // pass 2: moderate, relaxed confidence
                (560, 140, 0.15),   // pass 3: wide fallback
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

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = [
                    "zh-Hans", "zh-Hant", "en",
                    "ja", "ko", "fr", "de", "es"
                ]
                // Minimum text height to filter noise (in normalized coords 0..1)
                request.minimumTextHeight = 0.02

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do { try handler.perform([request]) } catch { continue }

                guard let observations = request.results,
                      !observations.isEmpty else { continue }

                // Filter by confidence, sort spatially: top→bottom then left→right
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
                        // Group by Y ± 0.03 tolerance → same line, then sort by X
                        if abs(a.y - b.y) > 0.03 { return a.y > b.y }  // top first
                        return a.x < b.x  // left to right within line
                    }

                guard !filtered.isEmpty else { continue }

                // Deduplicate adjacent identical tokens
                var deduped: [String] = []
                var prev = ""
                for item in filtered {
                    if item.text != prev { deduped.append(item.text) }
                    prev = item.text
                }

                // Join with line breaks between Y-groups
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

    private func captureViaSimulatedCopy() -> String? {
        let pb = NSPasteboard.general
        let initialCount = pb.changeCount
        let savedStrings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String]

        // Atomic restore with changeCount validation — only restore if our copy is the sole change
        defer {
            let currentCount = pb.changeCount
            if currentCount == initialCount + 1 {
                pb.clearContents()
                if let strings = savedStrings, !strings.isEmpty {
                    pb.setString(strings.joined(separator: "\n"), forType: .string)
                }
            }
            // else: user/third-party wrote during capture window — abandon restore
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

    private func captureViaAX() -> String? {
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

// ── C callback ──
private var _debounce = Date.distantPast
private var _ocrDebounce = Date.distantPast

private func unifiedHotkeyCallback(_: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let ptr = userData, let event else { return -1 }

    // Read EventHotKeyID from the Carbon event to know which hotkey was pressed
    var hid = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil,
        &hid
    )
    guard status == noErr else { return noErr }

    let now = Date()
    let mgr = Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()

    if hid.id == 1 {
        // Translate hotkey — no OCR fallback
        guard now.timeIntervalSince(_debounce) > 0.8 else { return noErr }
        _debounce = now
        let text = mgr.captureWithoutOCR()
        DispatchQueue.main.async { mgr.onHotkey?(text) }
    } else if hid.id == 2 {
        // OCR hotkey
        guard now.timeIntervalSince(_ocrDebounce) > 0.8 else { return noErr }
        _ocrDebounce = now
        DispatchQueue.main.async { mgr.onOCRHotkey?() }
    }

    return noErr
}

// ── AX convenience ──
private extension AXUIElement {
    func copyAttribute(_ attr: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attr, &value) == .success else { return nil }
        return value
    }
}
