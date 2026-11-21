import SwiftUI
import AppKit
import Carbon
import ScreenCaptureKit
import os
import DisplayGeometry

// MARK: - App Entry Point
// （审计修复）不再使用 SwiftUI App 生命周期 —— `Settings { EmptyView() }` 场景在
// 部分 macOS 版本会急切实例化并显示一个空白的「OmniTrans Settings」窗口。
// accessory 菜单栏应用不需要任何 Scene，改为手动 NSApplication 入口，
// 启动时零窗口。
@main
enum OmniTransEntry {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - App Delegate (v1.0 — Native NSMenu + Independent Settings)

/// ## Architecture
/// - **Status bar**: `NSStatusItem.menu = buildMenu()` — system-native.
/// - **Floating panel**: `WindowManager` (kept as-is).
/// - **Settings window**: `SettingsWindowManager` — independent `.titled` NSWindow.
///
/// No popover, no custom click-handling, no right-click hacks.
/// OCR 忙碌状态机（方案 A）——驱动菜单栏状态反馈：
/// - `.selecting`：用户正在框选区域
/// - `.parsing`：OCR 分析中（截图 + Vision）
/// - `.idle`：空闲（还原图标）
enum OCRBusyState {
    case idle, selecting, parsing
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Managers

    private let windowManager = WindowManager()
    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    /// 当前 OCR 忙碌状态（方案 A）——驱动菜单栏「正在识别…」稳定反馈。
    private var ocrBusyState: OCRBusyState = .idle
    /// 「正在识别…」看门狗 —— 超时强制复位 UI，杜绝永久转圈。
    private var ocrParsingWatchdog: Task<Void, Never>?
    /// OCR 状态提示 popover（`.applicationDefined`，不因点击外部/失焦自动关闭）。
    private var ocrStatusPopover: NSPopover?
    private var hotkeysDisabledItem: NSMenuItem?
    /// OCR 权限弹窗防抖：5 分钟内不重复弹出。
    private var lastPermissionAlertAt: ContinuousClock.Instant?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // ── 安装精简主菜单（Bug 修复）──
        // accessory 应用默认没有 mainMenu，而 NSTextField 的 ⌘C/⌘V/⌘X/⌘A
        // 快捷键依赖主菜单「编辑」项的 key equivalent 路由到响应者链。
        // 没有它，设置页所有输入框都无法粘贴（用户可直接输入但 ⌘V 无效）。
        installMinimalMainMenu()

        // Register all UserDefaults defaults once at startup.
        ConfigurationStore.registerDefaults()

        MemoryPurgeHelper.shared.registerMemoryWarningObserver()
        // （审计 C2）移除 MacOSNativeProvider.prewarmCache() —— 用常见词预热
        // 对真实查询命中率几乎为零，纯耗电；词典缓存改为按需填充。

#if DEBUG
        // ── 多屏布局诊断 ── 仅 Debug 构建运行，Release 不做无用功（审计 B3）──
        Task { @MainActor in await DisplayLayoutDebug.dump() }
#endif

        ThemeEngine.shared.apply()

        // Onboarding re-trigger from About page
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OmniTransShowOnboarding"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showOnboardingIfNeeded() }
        }

        // ── OCR loading indicator（方案 A：状态机统一驱动）──
        NotificationCenter.default.addObserver(forName: Notification.Name("OmniTransOCRLoading"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setOCRStatus(.parsing) }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("OmniTransOCRDone"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setOCRStatus(.idle) }
        }

        // ── OCR failure feedback (see OCRSelectionOverlay) ──
        for name in [NSNotification.Name("OmniTransOCRCaptureFailed"),
                     NSNotification.Name("OmniTransOCRNoTextFound"),
                     NSNotification.Name("OmniTransOCREngineBusy")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let msg: String
                let needsSettingsButton: Bool
                switch note.name.rawValue {
                case "OmniTransOCRCaptureFailed":
                    // 区分权限问题 vs 其他捕获错误
                    if #available(macOS 15.0, *), !CGPreflightScreenCaptureAccess() {
                        msg = "需要屏幕录制权限 — 请在系统设置中授权"
                        needsSettingsButton = true
                    } else {
                        msg = "屏幕捕获失败，请稍后重试"
                        needsSettingsButton = false
                    }
                case "OmniTransOCREngineBusy":
                    msg = "OCR 引擎繁忙，请稍后再试"
                    needsSettingsButton = false
                default:
                    msg = "所选区域未检测到文字，请重新框选"
                    needsSettingsButton = false
                }
                MainActor.assumeIsolated {
                    if needsSettingsButton {
                        // 权限问题 → 弹出可操作弹窗（含「打开系统设置」按钮）
                        if let last = self.lastPermissionAlertAt,
                           last.duration(to: .now) < .seconds(300) {
                            // 已经弹过 → 只显示简短提示
                            self.showStatusBarBubble(message: msg, duration: 3.0)
                        } else {
                            self.lastPermissionAlertAt = .now
                            self.showPermissionDeniedAlert()
                        }
                    } else {
                        self.showStatusBarBubble(message: msg, duration: 3.0)
                    }
                }
            }
        }

        // ── OCR permission denied — actionable alert with "Open Settings" button ──
        NotificationCenter.default.addObserver(forName: Notification.Name("OmniTransOCRPermissionDenied"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // 防抖：5 分钟内不重复弹窗（连续 OCR 失败会反复触发）
                if let last = self?.lastPermissionAlertAt,
                   last.duration(to: .now) < .seconds(300) { return }
                self?.lastPermissionAlertAt = .now
                self?.showPermissionDeniedAlert()
            }
        }

        // ── OCR warmup complete → proactive bubble ──
        NotificationCenter.default.addObserver(forName: .ocrWarmupComplete, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showStatusBarBubble(message: "OCR 引擎预热完毕，可以使用", duration: 3.0)
            }
        }

        // ── Hotkey callbacks ──
        HotkeyManager.shared.onHotkey = { [weak self] text, context in
            if let text, !text.isEmpty {
                self?.fire(text: text, context: context)
            } else {
                // 未取到文本 → 直接打开主窗口（工作区），供手动输入/选择历史（修复1）
                self?.showHistoryWorkspace()
            }
        }
        HotkeyManager.shared.onOCRHotkey = { [weak self] in
            let warmup = OCRWarmupState.shared
            // 缓存过期时静默触发后台重新预热（不置 isWarmingUp，不阻塞框选）
            warmup.ensureCacheValid()
            if warmup.isWarmingUp {
                self?.showStatusBarBubble(message: "OCR 引擎预热中，请稍候…", duration: 3.0)
                return
            }
            if warmup.warmupFailed {
                warmup.retryWarmup()
                self?.showStatusBarBubble(message: "OCR 引擎重新预热中…", duration: 3.0)
                return
            }
            self?.startOCRSelection()
        }
        HotkeyManager.shared.onReplaceHotkey = {
            let text = AppState.shared.translatedText
            guard !text.isEmpty else { return }
            // async 版本：不在主线程自旋，避免 UI 冻结
            Task { await TextReplacementService.shared.replaceSelectedText(with: text) }
        }

        AnimationGate.refresh()

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

        // ── ANE 冷启动预热（E5RT 故障修复）──
        // 实测启动后 1–2 分钟内 ANE 文字识别管线未就绪，用户首次 OCR
        // 会失败/停滞。启动即后台预热（失败自动重试至就绪），把冷启动
        // 成本移出用户路径。详见 Sources/OmniTrans/OCR/ANEWarmup.swift。
        Task.detached(priority: .utility) {
            await OCRCapturePipeline.warmUpANE()
        }

        // ── macOS 原生翻译引擎预热 ──
        // `LanguageAvailability.status()` 在冷启动时枚举语言包需 5-15 秒，
        // 不预热会导致首次原生翻译超时失败。预热带重试机制确保缓存建立。
        if #available(macOS 26.0, *) {
            SystemTranslationEngine.warmUp()
        }

        setupStatusItem()

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
        // 冲刷 provider 编辑的防抖保存，防止退出时丢失未落盘修改。
        AppState.shared.flushPendingSave()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Minimal Main Menu（编辑快捷键基础设施）

    /// 安装仅含 App 菜单 + 「编辑」菜单的隐藏主菜单。
    ///
    /// ## 原理
    /// accessory 应用不显示菜单栏，但 `NSApp.mainMenu` 的菜单项 key equivalent
    /// 仍参与按键路由。编辑项 action 为 nil target —— 由响应者链自动解析到
    /// 当前第一响应者（NSTextField/NSTextView），一处修复即恢复全部文本控件的
    /// ⌘Z/⌘X/⌘C/⌘V/⌘A。
    private func installMinimalMainMenu() {
        let mainMenu = NSMenu()

        // ── App 菜单 ──
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 OmniTrans",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 OmniTrans",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 OmniTrans",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // ── 编辑菜单 ──
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

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
        // NSStatusBarButton 的坐标系在 macOS 新版中不可靠，直接转换会偏移到屏幕最右侧。
        // 使用 popUpContextMenu 让 AppKit 基于当前点击事件自行定位，最准确可靠。
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        }
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
            Task { await TextReplacementService.shared.replaceSelectedText(with: text) }
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

        let popover = makeAdaptiveStatusPopover(
            message: message,
            font: NSFont.systemFont(ofSize: 12),
            textColor: .secondaryLabelColor,
            alignment: .natural,
            maxWidth: 320,
            behavior: .transient,
            animates: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            popover.close()
        }
    }

    /// 构造尺寸随文本自适应的状态栏气泡：宽度按文本实测（封顶 maxWidth），
    /// 高度随换行行数自适应。短消息（如「OCR 引擎预热中，请稍候…」）不再留大片空白。
    private func makeAdaptiveStatusPopover(message: String,
                                           font: NSFont,
                                           textColor: NSColor,
                                           alignment: NSTextAlignment,
                                           maxWidth: CGFloat,
                                           behavior: NSPopover.Behavior,
                                           animates: Bool) -> NSPopover {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = font
        label.textColor = textColor
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = alignment

        let paddingH: CGFloat = 24  // 左右各 12
        let paddingV: CGFloat = 14  // 上下各 7
        let singleLine = label.sizeThatFits(
            NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let contentWidth = min(singleLine.width, max(60, maxWidth - paddingH))
        let contentHeight = ceil(label.sizeThatFits(
            NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)).height)

        let view = NSView(frame: NSRect(x: 0, y: 0,
                                        width: ceil(contentWidth) + paddingH,
                                        height: contentHeight + paddingV))
        label.frame = view.bounds.insetBy(dx: 12, dy: 7)
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)

        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.behavior = behavior
        popover.animates = animates
        popover.contentViewController = controller
        return popover
    }

    private func fire(text: String?, context: CapturedContext? = nil) {
        // Pre-warm TCP/TLS while panel animates in — overlaps with UI
        HotkeyManager.shared.preConnectCurrentProvider()
        let s = AppState.shared
        s.resetForNew(text: text ?? "")
        showFloatingPanel()
        if let text, !text.isEmpty { s.translate(context: context) }
    }

    // ── OCR 状态反馈（方案 A）──

    /// 更新菜单栏 OCR 状态反馈：
    /// - `.selecting`：popover 提示「请拖选屏幕区域…」（框选阶段）
    /// - `.parsing`：statusItem 标题「正在识别…」（稳定主通道，点击/失焦不丢失）
    /// - `.idle`：还原图标与标题，关闭 popover
    private func setOCRStatus(_ state: OCRBusyState) {
        guard let button = statusItem?.button else { return }
        ocrBusyState = state
        switch state {
        case .selecting:
            dismissOCRStatusPopover()
            cancelParsingWatchdog()
            button.title = ""
            showOCRStatusPopover(message: "请拖选屏幕区域…")
        case .parsing:
            dismissOCRStatusPopover()
            button.title = "正在识别…"
            startParsingWatchdog()
        case .idle:
            dismissOCRStatusPopover()
            cancelParsingWatchdog()
            button.title = ""
            applyStatusBarIcon(to: button)
        }
    }

    // MARK: - Parsing Watchdog（端到端兑底）

    /// 「正在识别…」看门狗：管线各阶段虽已有自身超时，但任何一路延迟叠加都可能
    /// 让 Done 通知迟迟不到。60s 仍处于 parsing 则强制回 idle 并提示，
    /// 保证用户永远不会面对无上限的转圈。
    private func startParsingWatchdog() {
        cancelParsingWatchdog()
        ocrParsingWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, self.ocrBusyState == .parsing else { return }
            self.setOCRStatus(.idle)
            self.showStatusBarBubble(message: "OCR 识别超时，请重新框选", duration: 3.0)
        }
    }

    private func cancelParsingWatchdog() {
        ocrParsingWatchdog?.cancel()
        ocrParsingWatchdog = nil
    }

    /// 显示 OCR 状态 popover（`.applicationDefined`：不因点击外部/失焦自动关闭）。
    /// 尺寸随文本自适应，不再使用固定 200×40。
    private func showOCRStatusPopover(message: String) {
        guard let button = statusItem?.button else { return }
        dismissOCRStatusPopover()
        let popover = makeAdaptiveStatusPopover(
            message: message,
            font: NSFont.systemFont(ofSize: 12, weight: .medium),
            textColor: .labelColor,
            alignment: .center,
            maxWidth: 240,
            behavior: .applicationDefined,
            animates: false)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        ocrStatusPopover = popover
    }

    private func dismissOCRStatusPopover() {
        ocrStatusPopover?.close()
        ocrStatusPopover = nil
    }

    /// Shows an actionable alert when screen recording permission is denied.
    /// Includes a button to open System Settings > Privacy > Screen Recording.
    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "OCR 功能需要屏幕录制权限才能捕获屏幕内容。\n请在系统设置 → 隐私与安全性 → 屏幕录制中为 OmniTrans 授权。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        alert.icon = NSImage(systemSymbolName: "rectangle.dashed.badge.record", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Settings > Privacy & Security > Screen Recording
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func startOCRSelection() {
        // 预热未完成或失败时拦截 OCR 框选
        let warmup = OCRWarmupState.shared
        guard !warmup.isWarmingUp, !warmup.warmupFailed else {
            showStatusBarBubble(message: "OCR 引擎预热中，请稍候…", duration: 3.0)
            return
        }
        // 预检屏幕录制权限 —— 未授权时弹出系统授权对话框，不启动 OCR
        if #available(macOS 15.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                os_log(.info, log: OSLog(subsystem: AppLogging.subsystem, category: "OCR"),
                       "Screen Recording access not preflighted — requesting")
                CGRequestScreenCaptureAccess()
                // 延迟 1s 后检查是否已授权（系统弹窗可能被快速点击）
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    if !CGPreflightScreenCaptureAccess() {
                        self.showPermissionDeniedAlert()
                    }
                }
                return
            }
        }
        // 方案 A：框选开始即反馈，取词事件响应及时
        setOCRStatus(.selecting)
        OCRSelectionOverlay.shared.beginCapture { [weak self] result in
            guard let self, let result else {
                // OCR failed or cancelled — 恢复状态栏
                NotificationCenter.default.post(name: Notification.Name("OmniTransOCRDone"), object: nil)
                return
            }
            let s = AppState.shared
            s.resetForNew(text: result.text)
            // 方案 B：先 translate（同步置 isTranslating=true 或填充缓存结果），
            // 再弹窗 —— 面板首帧即为「正在翻译…」动画或缓存结果，杜绝空白/半渲染帧。
            s.translate()
            // 解析完成 → 恢复状态栏
            NotificationCenter.default.post(name: Notification.Name("OmniTransOCRDone"), object: nil)
            self.showFloatingPanel()
            // result.lines 携带每行文字在屏幕上的区域（AppKit 全局 bottom-left），
            // 可供后续原位替换 / 区域定位使用。
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

}
