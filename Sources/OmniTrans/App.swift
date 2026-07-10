import SwiftUI
import AppKit
import Carbon

// MARK: - App Entry Point

@main
struct OmniTransApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Color.clear.frame(width: 0, height: 0)
        }
        .defaultSize(width: 0, height: 0)
    }
}

// MARK: - App Delegate (v1.0 — Native NSMenu + Independent Settings)

/// ## Architecture
/// - **Status bar**: `NSStatusItem.menu = buildMenu()` — system-native.
/// - **Floating panel**: `WindowManager` (kept as-is).
/// - **Settings window**: `SettingsWindowManager` — independent `.titled` NSWindow.
///
/// No popover, no custom click-handling, no right-click hacks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Managers

    private let windowManager = WindowManager()
    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var hotkeysDisabledItem: NSMenuItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // ── Disable ANE (Apple Neural Engine) for Vision framework ──
        // On this M1 system, the TextRecognition E5 ANE model bundles are
        // corrupt/missing from the system framework (likely from a macOS
        // Sequoia OTA update).  Setting VNDisableANE forces Vision to run
        // its .accurate text recognition pipeline entirely on the CPU
        // (Espresso engine) instead of trying to load the broken ANE model.
        // This restores full OCR accuracy without character substitutions,
        // at the cost of slightly slower per-inference latency.
        setenv("VNDisableANE", "1", 1)

        // Register all UserDefaults defaults once at startup.
        ConfigurationStore.registerDefaults()

        MemoryPurgeHelper.shared.registerMemoryWarningObserver()
        MacOSNativeProvider.prewarmCache()

        // ── OCR hardware probe (runs once at startup) ──
        // Diagnoses whether .accurate (ANE/CPU) or .fast-only is
        // available on this system.  The result is stored in
        // OCRHardwareMode.current and used by all OCR calls.
        Task { await OCRHardwareDiagnostic.shared.run() }

        ThemeEngine.shared.apply()

        // Onboarding re-trigger from About page
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OmniTransShowOnboarding"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showOnboardingIfNeeded() }
        }

        // ── OCR failure feedback (see OCRSelectionOverlay) ──
        for name in [NSNotification.Name("OmniTransOCRCaptureFailed"),
                     NSNotification.Name("OmniTransOCRNoTextFound")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let msg: String
                if note.name.rawValue == "OmniTransOCRCaptureFailed" {
                    msg = "屏幕捕获失败，请检查「系统设置 → 隐私与安全性 → 屏幕录制」权限"
                } else {
                    msg = "所选区域未识别到文字"
                }
                MainActor.assumeIsolated {
                    self.showStatusBarBubble(message: msg, duration: 3.0)
                }
            }
        }

        // ── Hotkey callbacks ──
        HotkeyManager.shared.onHotkey = { [weak self] text, context in
            if let text, !text.isEmpty {
                self?.fire(text: text, context: context)
            } else {
                self?.showHistoryWorkspace()
            }
        }
        HotkeyManager.shared.onOCRHotkey = { [weak self] in self?.startOCRSelection() }
        HotkeyManager.shared.onReplaceHotkey = {
            let text = AppState.shared.translatedText
            guard !text.isEmpty else { return }
            TextReplacementService.shared.replaceSelectedText(with: text)
        }

        AnimationGate.refresh()

        // ── Install shared Carbon event handler once at startup ──
        HotkeyManager.setup()

        // Only register hotkeys if user hasn't disabled them
        if UserDefaults.standard.bool(forKey: "hotkeys_enabled") {
            HotkeyManager.shared.register()
            HotkeyManager.shared.registerOCR()
            HotkeyManager.shared.registerReplace()
        }

        if UserDefaults.standard.bool(forKey: "clipboard_monitor") {
            ClipboardMonitor.shared.start()
        }

        // Pre-warm TCP/TLS to current provider on cold start
        HotkeyManager.shared.preConnectCurrentProvider()

        setupStatusItem()
        hidePlaceholderWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showOnboardingIfNeeded()
        }
    }


    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
        HotkeyManager.shared.unregisterOCR()
        HotkeyManager.shared.unregisterReplace()
        ClipboardMonitor.shared.stop()
        onboardingWindow?.close()
        windowManager.dismissAll()

        // Best-effort flush: JSONL writes are synchronous once started,
        // and the system flushes file buffers during normal exit.
        // No blocking on the main thread — Swift 6 forbids it.
        Task { await HistoryActor.shared.flushNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        applyStatusBarIcon(to: button)

        // Use button action with NSMenu.popUp — works for both left & right click
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func applyStatusBarIcon(to button: NSStatusBarButton) {
        if let path = Bundle.main.path(forResource: "menubar", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            icon.isTemplate = true
            icon.size = NSSize(width: 22, height: 22)
            button.image = icon
        } else {
            let img = NSImage(
                systemSymbolName: "character.bubble.fill",
                accessibilityDescription: "OmniTrans"
            )
            img?.isTemplate = true
            button.image = img
        }
    }

    // 点击菜单栏图标显示快捷菜单（划词/OCR/替换/首选项/退出）。
    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        let menu = buildMenu()
        menu.delegate = self
        menu.appearance = NSApp.effectiveAppearance
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    // MARK: - NSMenu Construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // ── Translate ──
        let translateItem = menuItem(
            title: "划词翻译",
            action: #selector(menuTranslate),
            key: hotkeyKeyEquivalent(for: "hotkey"),
            modifiers: hotkeyModifiers(for: "hotkey")
        )
        menu.addItem(translateItem)

        // ── OCR ──
        let ocrItem = menuItem(
            title: "OCR 翻译",
            action: #selector(menuOCR),
            key: hotkeyKeyEquivalent(for: "ocr_hotkey"),
            modifiers: hotkeyModifiers(for: "ocr_hotkey")
        )
        menu.addItem(ocrItem)

        // ── Replace ──
        let replaceItem = menuItem(
            title: "原位替换",
            action: #selector(menuReplace),
            key: hotkeyKeyEquivalent(for: "replace"),
            modifiers: hotkeyModifiers(for: "replace")
        )
        menu.addItem(replaceItem)

        menu.addItem(.separator())

        // ── Disable Hotkeys Toggle ──
        let hotkeysOn = UserDefaults.standard.bool(forKey: "hotkeys_enabled")
        let disableItem = NSMenuItem(
            title: "禁用快捷键",
            action: #selector(menuToggleHotkeys),
            keyEquivalent: ""
        )
        disableItem.target = self
        disableItem.state = hotkeysOn ? .off : .on
        hotkeysDisabledItem = disableItem
        menu.addItem(disableItem)

        menu.addItem(.separator())

        // ── Default Translate API ──
        let translateAPISub = NSMenu()
        translateAPISub.autoenablesItems = false
        let translateAPIItem = NSMenuItem(title: "默认翻译 API", action: nil, keyEquivalent: "")
        translateAPIItem.tag = 100 // unique tag for identifier-based lookup
        translateAPIItem.submenu = translateAPISub
        menu.addItem(translateAPIItem)

        // ── Default Dictionary API ──
        let dictAPISub = NSMenu()
        dictAPISub.autoenablesItems = false
        let dictAPIItem = NSMenuItem(title: "默认查词 API", action: nil, keyEquivalent: "")
        dictAPIItem.tag = 101 // unique tag for identifier-based lookup
        dictAPIItem.submenu = dictAPISub
        menu.addItem(dictAPIItem)

        menu.addItem(.separator())

        // ── Preferences ──
        menu.addItem(menuItem(
            title: "首选项…",
            action: #selector(menuPreferences),
            key: ",",
            modifiers: .command
        ))

        // ── Quit ──
        menu.addItem(menuItem(
            title: "退出 OmniTrans",
            action: #selector(menuQuit),
            key: "q",
            modifiers: .command
        ))

        return menu
    }

    // MARK: - NSMenuDelegate — Dynamically populate API submenus

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh hotkey toggle state
        let hotkeysOn = UserDefaults.standard.bool(forKey: "hotkeys_enabled")
        hotkeysDisabledItem?.state = hotkeysOn ? .off : .on

        // Rebuild API submenus (items 6 = translate API, 7 = dict API after dividers)
        rebuildAPISubmenus(in: menu)
    }

    private func rebuildAPISubmenus(in menu: NSMenu) {
        let state = AppState.shared
        let providers = state.enabledProviders

        // ── Translate API submenu (look up by tag 100) ──
        if let translateSub = menu.item(withTag: 100)?.submenu {
            translateSub.removeAllItems()
            for p in providers {
                let item = NSMenuItem(
                    title: "\(p.name) · \(p.modelName)",
                    action: #selector(menuSelectTranslateAPI(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = p.id as UUID
                item.state = (state.selectedProviderID == p.id) ? .on : .off
                item.target = self
                translateSub.addItem(item)
            }
        }

        // ── Dictionary API submenu (look up by tag 101) ──
        if let dictSub = menu.item(withTag: 101)?.submenu {
            dictSub.removeAllItems()
            // "跟随当前选择" option
            let followItem = NSMenuItem(
                title: "跟随当前选择",
                action: #selector(menuSelectDictAPI(_:)),
                keyEquivalent: ""
            )
            followItem.representedObject = nil as UUID?
            followItem.state = (state.dictProviderID == nil) ? .on : .off
            followItem.target = self
            dictSub.addItem(followItem)

            dictSub.addItem(.separator())

            for p in providers {
                let item = NSMenuItem(
                    title: "\(p.name) · \(p.modelName)",
                    action: #selector(menuSelectDictAPI(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = p.id as UUID
                item.state = (state.dictProviderID == p.id) ? .on : .off
                item.target = self
                dictSub.addItem(item)
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func menuTranslate() {
        let text = HotkeyManager.shared.captureWithoutOCR()
        let context: CapturedContext? = text.flatMap {
            SlidingWindowContextCapture.capture(selectedText: $0)
        }
        // NSMenu auto-dismisses — fire after a tick for clean state
        DispatchQueue.main.async { [weak self] in
            if let text, !text.isEmpty {
                self?.fire(text: text, context: context)
            } else {
                self?.showHistoryWorkspace()
            }
        }
    }

    @objc private func menuOCR() {
        DispatchQueue.main.async { [weak self] in
            self?.startOCRSelection()
        }
    }

    @objc private func menuReplace() {
        DispatchQueue.main.async {
            let text = AppState.shared.translatedText
            guard !text.isEmpty else { return }
            TextReplacementService.shared.replaceSelectedText(with: text)
        }
    }

    @objc private func menuToggleHotkeys() {
        let current = UserDefaults.standard.bool(forKey: "hotkeys_enabled")
        let newValue = !current
        UserDefaults.standard.set(newValue, forKey: "hotkeys_enabled")
        hotkeysDisabledItem?.state = newValue ? .off : .on  // on = disabled

        if newValue {
            HotkeyManager.shared.unregister()
            HotkeyManager.shared.unregisterOCR()
            HotkeyManager.shared.unregisterReplace()
        } else {
            HotkeyManager.shared.register()
            HotkeyManager.shared.registerOCR()
            HotkeyManager.shared.registerReplace()
        }
    }

    @objc private func menuSelectTranslateAPI(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              AppState.shared.enabledProviders.contains(where: { $0.id == id })
        else { return }
        AppState.shared.selectedProviderID = id
        ProviderStorageManager.saveSelectedProviderID(id)
    }

    @objc private func menuSelectDictAPI(_ sender: NSMenuItem) {
        let id = sender.representedObject as? UUID
        AppState.shared.dictProviderID = id
        if let id {
            ProviderStorageManager.saveDictProviderID(id)
        }
    }

    @objc private func menuPreferences() {
        SettingsWindowManager.shared.show()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey → NSMenuItem Helpers

    /// Reads Carbon key code + modifiers from UserDefaults, returns keyEquivalent.
    private func hotkeyKeyEquivalent(for prefix: String) -> String {
        let carbonKey: Int
        switch prefix {
        case "ocr_hotkey": carbonKey = UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonKey")
        case "replace":    carbonKey = UserDefaults.standard.integer(forKey: "replace_hotkey_carbonKey")
        default:           carbonKey = UserDefaults.standard.integer(forKey: "hotkey_carbonKey")
        }
        return carbonKeyToString(UInt16(carbonKey))
    }

    /// Reads Carbon modifier mask from UserDefaults, returns NSEvent.ModifierFlags.
    private func hotkeyModifiers(for prefix: String) -> NSEvent.ModifierFlags {
        let carbonMods: Int
        switch prefix {
        case "ocr_hotkey": carbonMods = UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonMods")
        case "replace":    carbonMods = UserDefaults.standard.integer(forKey: "replace_hotkey_carbonMods")
        default:           carbonMods = UserDefaults.standard.integer(forKey: "hotkey_carbonMods")
        }
        return carbonToEventModifiers(UInt32(carbonMods))
    }

    /// Convert Carbon key code → keyEquivalent string.
    private func carbonKeyToString(_ code: UInt16) -> String {
        return switch code {
        case UInt16(kVK_ANSI_A): "a"; case UInt16(kVK_ANSI_D): "d"
        case UInt16(kVK_ANSI_T): "t"; case UInt16(kVK_ANSI_S): "s"
        case UInt16(kVK_ANSI_W): "w"; case UInt16(kVK_ANSI_E): "e"
        case UInt16(kVK_ANSI_R): "r"; case UInt16(kVK_ANSI_F): "f"
        case UInt16(kVK_ANSI_X): "x"; case UInt16(kVK_ANSI_C): "c"
        case UInt16(kVK_ANSI_V): "v"; case UInt16(kVK_ANSI_G): "g"
        case UInt16(kVK_ANSI_B): "b"; case UInt16(kVK_ANSI_H): "h"
        case UInt16(kVK_ANSI_N): "n"; case UInt16(kVK_ANSI_J): "j"
        case UInt16(kVK_ANSI_M): "m"; case UInt16(kVK_ANSI_K): "k"
        case UInt16(kVK_ANSI_L): "l"; case UInt16(kVK_ANSI_O): "o"
        case UInt16(kVK_ANSI_P): "p"; case UInt16(kVK_ANSI_Q): "q"
        case UInt16(kVK_ANSI_U): "u"; case UInt16(kVK_ANSI_I): "i"
        case UInt16(kVK_ANSI_Y): "y"; case UInt16(kVK_ANSI_Z): "z"
        case UInt16(kVK_ANSI_0): "0"; case UInt16(kVK_ANSI_1): "1"
        case UInt16(kVK_ANSI_2): "2"; case UInt16(kVK_ANSI_3): "3"
        case UInt16(kVK_ANSI_4): "4"; case UInt16(kVK_ANSI_5): "5"
        case UInt16(kVK_ANSI_6): "6"; case UInt16(kVK_ANSI_7): "7"
        case UInt16(kVK_ANSI_8): "8"; case UInt16(kVK_ANSI_9): "9"
        case UInt16(kVK_ANSI_Minus): "-"
        case UInt16(kVK_ANSI_Equal): "="
        case UInt16(kVK_ANSI_LeftBracket): "["
        case UInt16(kVK_ANSI_RightBracket): "]"
        case UInt16(kVK_ANSI_Backslash): "\\"
        case UInt16(kVK_ANSI_Semicolon): ";"
        case UInt16(kVK_ANSI_Quote): "'"
        case UInt16(kVK_ANSI_Comma): ","
        case UInt16(kVK_ANSI_Period): "."
        case UInt16(kVK_ANSI_Slash): "/"
        case UInt16(kVK_ANSI_Grave): "`"
        case UInt16(kVK_Return): "\r"
        case UInt16(kVK_Tab):    "\t"
        case UInt16(kVK_Escape): "\u{1B}"
        case UInt16(kVK_Delete): "\u{8}"
        case UInt16(kVK_Space):  " "
        default: ""
        }
    }

    /// Convert Carbon modifier mask → NSEvent.ModifierFlags.
    private func carbonToEventModifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey)  != 0 { flags.insert(.option) }
        if carbon & UInt32(shiftKey)   != 0 { flags.insert(.shift) }
        if carbon & UInt32(cmdKey)     != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: - Floating Panel (delegated)

    func showFloatingPanel() {
        windowManager.showFloating(nearMouse: true)
    }

    private func showHistoryWorkspace() {
        AppState.shared.resetForNew(text: "")
        showFloatingPanel()
    }

    /// Shows a transient macOS notification-style bubble anchored to the
    /// status bar item.  Used for non-critical feedback (e.g. OCR failure).
    private func showStatusBarBubble(message: String, duration: TimeInterval) {
        guard let button = statusItem?.button, let _ = button.window else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = controller.view.bounds.insetBy(dx: 12, dy: 8)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor.secondaryLabelColor
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.autoresizingMask = [NSView.AutoresizingMask.width, .height]
        controller.view.addSubview(label)
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            popover.close()
        }
    }

    private func fire(text: String?, context: CapturedContext? = nil) {
        // Pre-warm TCP/TLS while panel animates in — overlaps with UI
        HotkeyManager.shared.preConnectCurrentProvider()
        let s = AppState.shared
        s.resetForNew(text: text ?? "")
        showFloatingPanel()
        if let text, !text.isEmpty { s.translate(context: context) }
    }

    private func startOCRSelection() {
        OCRSelectionOverlay.shared.beginCapture { [weak self] text in
            guard let self, let text else { return }
            let s = AppState.shared
            s.resetForNew(text: text)
            self.showFloatingPanel()
            s.translate()
        }
    }

    // MARK: - NSMenuItem Factory

    private func menuItem(title: String, action: Selector, key: String,
                           modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: - Onboarding

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "has_completed_onboarding") else { return }
        let contentView = OnboardingView { [weak self] in self?.dismissOnboarding() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "欢迎使用 OmniTrans"
        window.contentView = NSHostingView(rootView: contentView.withTheme())
        window.center()
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
    }

    private func dismissOnboarding() {
        UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
        onboardingWindow?.close()
        onboardingWindow = nil
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hidePlaceholderWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if window.contentView?.subviews.first is NSHostingView<SwiftUI.Color> {
                    window.close()
                }
            }
        }
    }

}
