import Carbon
import Cocoa
import os

// MARK: - Debounce Controller (Sendable)

/// Thread-safe debounce state — uses `OSAllocatedUnfairLock` for synchronous
/// access from both the Carbon event thread and `@MainActor` contexts.
/// `OSAllocatedUnfairLock` is the Swift 6 recommended replacement for `NSLock`.
final class DebounceController: @unchecked Sendable {
    static let shared = DebounceController()

    private let lock = OSAllocatedUnfairLock()
    private var _debounceTime = Date.distantPast
    private var _ocrDebounceTime = Date.distantPast
    private var _replaceDebounceTime = Date.distantPast

    /// Atomically checks and updates the debounce timestamp for `id`.
    /// Returns `true` if the hotkey should be processed, `false` to ignore.
    func checkAndUpdate(id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        switch id {
        case 1:
            guard now.timeIntervalSince(_debounceTime) > 0.8 else { return false }
            _debounceTime = now
        case 2:
            guard now.timeIntervalSince(_ocrDebounceTime) > 0.8 else { return false }
            _ocrDebounceTime = now
        case 3:
            guard now.timeIntervalSince(_replaceDebounceTime) > 0.8 else { return false }
            _replaceDebounceTime = now
        default:
            return false
        }
        return true
    }
}

// MARK: - Capture Pipeline (Sendable)

/// Immutable capture strategy arrays.  Declared as `nonisolated(unsafe)` static
/// lets — they are never mutated after initialization and all elements conform
/// to `Sendable`, making cross-isolation access sound.
private nonisolated(unsafe) let translateStrategies: [any TextCaptureStrategy] = [
    ClipboardCaptureStrategy(),
    AXCaptureStrategy()
]

private nonisolated(unsafe) let ocrStrategies: [any TextCaptureStrategy] = [
    ClipboardCaptureStrategy(),
    AXCaptureStrategy(),
    ScreenCaptureOCRCaptureStrategy()
]

/// 划词取词: CGEvent 模拟 Cmd+C (需辅助功能权限) → AX fallback
///
/// Swift 6 严格并发: 整个管理器隔离在 `@MainActor` 上。
/// Carbon C 回调通过 `nonisolated` 方法和 `DebounceController` 桥接，
/// 实际的回调闭包始终在 MainActor 上执行。
@MainActor
final class HotkeyManager {
    // @MainActor 类的静态共享实例默认隔离到主线程；所有访问点均在 MainActor 上下文。
    static let shared = HotkeyManager()

    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// Callback when translate hotkey is pressed.
    /// - Parameter 1: captured text (nil if no text was captured)
    /// - Parameter 2: bidirectional sliding-window context (nil if unavailable)
    var onHotkey: (@MainActor (String?, CapturedContext?) -> Void)?

    // OCR capture hotkey (Opt+F by default)
    private var ocrHotkeyRef: EventHotKeyRef?
    private var replaceHotkeyRef: EventHotKeyRef?
    var onOCRHotkey: (@MainActor () -> Void)?
    var onReplaceHotkey: (@MainActor () -> Void)?

    // MARK: - Debounce (thread-safe via DebounceController)

    /// Checks whether `id` has satisfied the debounce interval (0.8 s).
    /// `nonisolated` so the Carbon C callback can call it synchronously
    /// without crossing actor boundaries.
    nonisolated func checkDebounce(id: Int) -> Bool {
        DebounceController.shared.checkAndUpdate(id: id)
    }

    /// 当前是否拥有辅助功能权限
    nonisolated static var isTrusted: Bool {
        let trusted = AXIsProcessTrusted()
        #if DEBUG
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        os_log(.debug, log: OSLog(subsystem: bundleID, category: "Permissions"),
               "[AX] isTrusted=%{public}@ bundleID=%{public}@",
               String(describing: trusted), bundleID)
        #endif
        return trusted
    }

    // MARK: - Accessibility Permission (lazy, on first hotkey use)

    /// 在首次使用划词时请求辅助功能权限，仅使用系统原生弹窗。
    /// 线程安全，可从 Carbon 回调线程调用。
    nonisolated static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        #if DEBUG
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        os_log(.info, log: OSLog(subsystem: bundleID, category: "Permissions"),
               "[AX] Requesting accessibility permission... bundleID=%{public}@", bundleID)
        #endif
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let result = AXIsProcessTrustedWithOptions(opts)
        #if DEBUG
        os_log(.info, log: OSLog(subsystem: bundleID, category: "Permissions"),
               "[AX] Permission request result: %{public}@", String(describing: result))
        #endif
        return result
    }

    /// Format a hotkey label from Carbon key/mod values e.g. "⌥D"
    nonisolated static func hotkeyLabelFrom(carbonKey: Int, carbonMods: Int) -> String {
        let key = UInt32(carbonKey)
        return modifiersToSymbols(UInt32(carbonMods)) + keyToString(UInt16(key))
    }

    /// Shared modifier → symbol conversion (⌃⌥⇧⌘).
    nonisolated private static func modifiersToSymbols(_ mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// 当前翻译快捷键的显示字符串 e.g. "⌥D"
    nonisolated static func hotkeyLabel() -> String {
        let mods = resolvedMods(for: "hotkey_carbonMods", defaultMod: optionKey)
        let key  = resolvedKey(for: "hotkey_carbonKey", defaultKey: kVK_ANSI_D)
        return modifiersToSymbols(mods) + keyToString(UInt16(key))
    }

    /// 当前原位替换快捷键的显示字符串 e.g. "⌥R"
    nonisolated static func replaceHotkeyLabel() -> String {
        let mods = resolvedMods(for: "replace_hotkey_carbonMods", defaultMod: optionKey)
        let key  = resolvedKey(for: "replace_hotkey_carbonKey", defaultKey: kVK_ANSI_R)
        return modifiersToSymbols(mods) + keyToString(UInt16(key))
    }

    /// 当前 OCR 框选快捷键的显示字符串 e.g. "⌥F"
    nonisolated static func ocrHotkeyLabel() -> String {
        let mods = resolvedMods(for: "ocr_hotkey_carbonMods", defaultMod: optionKey)
        let key  = resolvedKey(for: "ocr_hotkey_carbonKey", defaultKey: kVK_ANSI_F)
        return modifiersToSymbols(mods) + keyToString(UInt16(key))
    }

    nonisolated private static func resolvedMods(for udKey: String, defaultMod: Int) -> UInt32 {
        let m = UserDefaults.standard.integer(forKey: udKey)
        return m != 0 ? UInt32(m) : UInt32(defaultMod)
    }

    nonisolated private static func resolvedKey(for udKey: String, defaultKey: Int) -> UInt32 {
        let k = UserDefaults.standard.integer(forKey: udKey)
        return k != 0 ? UInt32(k) : UInt32(defaultKey)
    }

    nonisolated private static func keyToString(_ code: UInt16) -> String {
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
    nonisolated private static func keyCodeToStringViaSystem(_ keyCode: UInt16) -> String? {
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
    nonisolated static func carbonMods(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    /// 统一安装唯一的 Carbon 事件处理器（三个热键共用）。
    /// 避免对每个热键重复 `InstallEventHandler` 造成重复分发（审计 M6）。
    private func ensureHandlerInstalled() {
        guard handlerRef == nil else { return }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), unifiedHotkeyCallback, 1,
                            &spec, ptr, &ref)
        handlerRef = ref
    }

    func register() {
        let m = UserDefaults.standard.integer(forKey: "hotkey_carbonMods")
        let k = UserDefaults.standard.integer(forKey: "hotkey_carbonKey")
        let mods = m != 0 ? UInt32(m) : UInt32(optionKey)
        let key  = k != 0 ? UInt32(k) : UInt32(kVK_ANSI_D)
        let hid = EventHotKeyID(signature: 0x4149544C, id: 1)
        RegisterEventHotKey(key, mods, hid, GetApplicationEventTarget(), 0, &hotkeyRef)
        ensureHandlerInstalled()
    }

    func unregister() {
        if let r = hotkeyRef  { UnregisterEventHotKey(r); hotkeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }

    // MARK: - OCR hotkey (⌥F by default)

    func registerOCR() {
        let m = UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonMods")
        let k = UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonKey")
        let mods = m != 0 ? UInt32(m) : UInt32(optionKey)
        let key  = k != 0 ? UInt32(k) : UInt32(kVK_ANSI_F)
        let hid = EventHotKeyID(signature: 0x4149544C, id: 2)
        RegisterEventHotKey(key, mods, hid,
                            GetApplicationEventTarget(), 0, &ocrHotkeyRef)
        ensureHandlerInstalled()
    }

    // MARK: - Replace hotkey (⌥R by default)

    func registerReplace() {
        let hid = EventHotKeyID(signature: 0x4149544C, id: 3)
        let m = UserDefaults.standard.integer(forKey: "replace_hotkey_carbonMods")
        let k = UserDefaults.standard.integer(forKey: "replace_hotkey_carbonKey")
        let mods = m != 0 ? UInt32(m) : UInt32(optionKey)
        let key  = k != 0 ? UInt32(k) : UInt32(kVK_ANSI_R)
        RegisterEventHotKey(key, mods, hid,
                            GetApplicationEventTarget(), 0, &replaceHotkeyRef)
        ensureHandlerInstalled()
    }

    func unregisterReplace() {
        if let r = replaceHotkeyRef  { UnregisterEventHotKey(r); replaceHotkeyRef = nil }
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

    /// Re-register replace hotkey (called after user customization)
    func reregisterReplace(carbonKey: Int, carbonMods: Int) {
        unregisterReplace()
        UserDefaults.standard.set(carbonKey, forKey: "replace_hotkey_carbonKey")
        UserDefaults.standard.set(carbonMods, forKey: "replace_hotkey_carbonMods")
        registerReplace()
    }

    /// Reset replace hotkey to default (Option+R)
    func resetReplaceToDefault() {
        reregisterReplace(carbonKey: Int(kVK_ANSI_R), carbonMods: Int(optionKey))
    }

    func unregisterOCR() {
        if let r = ocrHotkeyRef  { UnregisterEventHotKey(r); ocrHotkeyRef = nil }
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

    // MARK: - Capture pipeline (Chain of Responsibility)

    /// Translate-only capture: Simulated Cmd+C → AX API (no OCR fallback)
    /// `nonisolated` so the Carbon C callback can call it from the background.
    nonisolated func capture() -> String? {
        for strategy in translateStrategies {
            if let text = strategy.tryCapture() { return text }
        }
        return nil
    }

    /// Alias for translate hotkey callback — identical to capture()
    nonisolated func captureWithoutOCR() -> String? {
        return capture()
    }

    /// Full capture with OCR fallback (used by OCR hotkey and internally)
    nonisolated func captureWithOCR() -> String? {
        for strategy in ocrStrategies {
            if let text = strategy.tryCapture() { return text }
        }
        return nil
    }
}

// ── C callback ──
// All capture strategies (Clipboard polling, AX queries, OCR) now run on
// a background queue so they never block the Carbon event thread.  The
// debounce check happens synchronously (DebounceController) so it
// returns in < 1 µs and doesn't stall event dispatch.
//
// The `HotkeyManager` is `@MainActor`, so callback invocations are
// dispatched to `DispatchQueue.main.async`.  Capture methods are
// `nonisolated` so they can run off the main thread without blocking UI.

private func unifiedHotkeyCallback(_: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let ptr = userData, let event else { return -1 }

    var hid = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil,
        &hid
    )
    guard status == noErr else { return noErr }

    let mgr = Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
    guard mgr.checkDebounce(id: Int(hid.id)) else { return noErr }

    if hid.id == 1 {
        // ── 首次使用划词时才请求辅助功能权限 ──
        _ = HotkeyManager.requestAccessibilityIfNeeded()
        DispatchQueue.main.async { mgr.preConnectCurrentProvider() }
        // Offload capture to a background queue so Clipboard polling /
        // AX queries never block the Carbon event thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let text = mgr.captureWithoutOCR()
            let context: CapturedContext? = text.flatMap { SlidingWindowContextCapture.capture(selectedText: $0) }
            DispatchQueue.main.async { mgr.onHotkey?(text, context) }
        }
    } else if hid.id == 2 {
        // ── OCR 也先检查权限，避免 Clipboard/AX 策略静默失败 ──
        _ = HotkeyManager.requestAccessibilityIfNeeded()
        DispatchQueue.main.async { mgr.preConnectCurrentProvider() }
        DispatchQueue.main.async { mgr.onOCRHotkey?() }
    } else if hid.id == 3 {
        DispatchQueue.main.async { mgr.onReplaceHotkey?() }
    }

    return noErr
}

// MARK: - Network Pre-connect (TCP/TLS Warmup)

extension HotkeyManager {

    /// Sends an ultra-lightweight HEAD request to the current provider's API
    /// host to complete DNS resolution + TCP + TLS handshake before the actual
    /// translation request fires.  This eliminates ~50ms+ of cold-start
    /// connection latency by ensuring the HTTP/2 connection is already
    /// established and pooled when `TranslationActor` sends the real POST.
    ///
    /// Called from the Carbon hotkey callback *before* text capture so the
    /// handshake overlaps with the capture pipeline (Cmd+C simulation, OCR,
    /// etc.).  Fire-and-forget — errors are silently ignored.
    @MainActor
    func preConnectCurrentProvider() {
        guard let provider = AppState.shared.selectedProvider,
              provider.kind != .macOSNative,
              let url = URL(string: provider.baseURL)
        else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = NetworkConfig.warmupTimeout  // Short timeout — best-effort only

        let task = sharedURLSession.dataTask(with: req) { _, _, _ in
            // Fire-and-forget; connection is now in the shared pool
        }
        task.resume()
    }
}

