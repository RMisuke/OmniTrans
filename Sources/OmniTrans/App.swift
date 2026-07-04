import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct OmniTransApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// V0.6: MenuBarExtra(.window) 无法自定义底层 NSWindow 的 styleMask，
    /// 导致窗口边框与内部圆角模糊背景不匹配。改用 NSStatusItem + NSPanel
    /// 架构（AppDelegate 中管理），此处仅放置零尺寸 WindowGroup 满足
    /// SwiftUI App 协议的最低场景要求。
    var body: some Scene {
        WindowGroup {
            Color.clear
                .frame(width: 0, height: 0)
        }
        .defaultSize(width: 0, height: 0)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var didSetup = false
    private var onboardingWindow: NSWindow?

    // ── Menu bar icon + settings panel ──
    private var statusItem: NSStatusItem?
    private var settingsPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标，防止 WindowGroup 创建可见窗口。
        // 菜单栏图标由 NSStatusItem 单独管理。
        NSApp.setActivationPolicy(.accessory)

        MemoryPurgeHelper.shared.registerMemoryWarningObserver()
        MacOSNativeProvider.prewarmCache()

        let mode = UserDefaults.standard.string(forKey: "app_appearance") ?? "system"
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }

        HotkeyManager.shared.onHotkey = { [weak self] text, context in
            if let text, !text.isEmpty {
                self?.fire(text: text, context: context)
            } else {
                self?.showHistoryWorkspace()
            }
        }
        AnimationGate.refresh()
        HotkeyManager.shared.register()

        HotkeyManager.shared.onOCRHotkey = { [weak self] in
            self?.startOCRSelection()
        }
        HotkeyManager.shared.registerOCR()

        HotkeyManager.shared.onReplaceHotkey = {
            let text = AppState.shared.translatedText
            guard !text.isEmpty else { return }
            TextReplacementService.shared.replaceSelectedText(with: text)
        }
        HotkeyManager.shared.registerReplace()

        if UserDefaults.standard.bool(forKey: "clipboard_monitor") {
            ClipboardMonitor.shared.start()
        }

        // ── Setup menu bar icon ──
        setupStatusItem()

        // ── Style the WindowGroup placeholder window (hide it) ──
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
        onboardingWindow = nil
        settingsPanel?.close()
        settingsPanel = nil
        Task { await HistoryActor.shared.flushNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Hide Placeholder Window

    /// Immediately close the zero-size WindowGroup window so it never appears.
    private func hidePlaceholderWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if window.contentView?.subviews.first is NSHostingView<SwiftUI.Color> {
                    window.close()
                }
            }
        }
    }

    // MARK: - Status Item (menu bar icon)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        // 【修复】菜单栏图标模板化 + 正确尺寸
        if let path = Bundle.main.path(forResource: "menubar", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            icon.isTemplate = true               // 关键：模板化适配亮/暗菜单栏
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
        } else {
            button.image = NSImage(
                systemSymbolName: "character.bubble.fill",
                accessibilityDescription: "OmniTrans"
            )
        }

        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "退出 OmniTrans", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }
        toggleSettingsPanel()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings Panel (borderless NSPanel, 20pt continuous corners)

    private func toggleSettingsPanel() {
        if let panel = settingsPanel, panel.isVisible {
            panel.close()
            return
        }

        let state = AppState.shared
        // V0.6: 菜单栏直显设置页，不经过 ContentView 翻译页
        let contentView = SettingsView(state: state, isPresented: .constant(false))

        if settingsPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .transient]
            panel.isMovableByWindowBackground = false
            panel.hidesOnDeactivate = false

            let hosting = NSHostingView(rootView: contentView)
            hosting.frame = NSRect(x: 0, y: 0, width: 440, height: 500)
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 20
            hosting.layer?.cornerCurve = .continuous
            hosting.layer?.masksToBounds = true
            panel.contentView = hosting

            // Click-outside dismiss
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak panel] event in
                guard let panel, panel.isVisible else { return event }
                let loc = event.locationInWindow
                if let cv = panel.contentView, !cv.bounds.contains(cv.convert(loc, from: nil)) {
                    panel.close()
                }
                return event
            }

            settingsPanel = panel
        } else if let hosting = settingsPanel?.contentView as? NSHostingView<SettingsView> {
            hosting.rootView = contentView
        }

        positionSettingsPanel()
        settingsPanel?.makeKeyAndOrderFront(nil)
        settingsPanel?.invalidateShadow()
    }

    private func positionSettingsPanel() {
        guard let panel = settingsPanel else { return }
        let pw: CGFloat = 440, ph: CGFloat = 500

        guard let screen = NSScreen.main else {
            panel.center()
            return
        }

        if let button = statusItem?.button, let buttonWindow = button.window {
            let buttonScreenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var ox = buttonScreenRect.midX - pw / 2
            var oy = screen.frame.maxY - ph - 4

            if ox < screen.frame.minX + 8 { ox = screen.frame.minX + 8 }
            if ox + pw > screen.frame.maxX - 8 { ox = screen.frame.maxX - pw - 8 }
            if oy < screen.frame.minY + 40 { oy = screen.frame.minY + 40 }

            panel.setFrame(NSRect(x: ox, y: oy, width: pw, height: ph), display: false)
            return
        }

        let ox = screen.frame.midX - pw / 2
        let oy = screen.frame.midY - ph / 2
        panel.setFrame(NSRect(x: ox, y: oy, width: pw, height: ph), display: false)
    }

    // MARK: - OCR

    private func startOCRSelection() {
        OCRSelectionOverlay.shared.beginCapture { [weak self] text in
            guard let self, let text else { return }
            let s = AppState.shared
            s.resetForNew(text: text)
            self.showFloatingPanel()
            s.translate()
        }
    }

    func showFloatingPanel() {
        if !didSetup {
            let p = FloatingPanel.shared
            p.setFrame(NSRect(x: 0, y: 0, width: 420, height: 380), display: false)
            p.contentView = NSHostingView(rootView: FloatingTranslationView(state: AppState.shared)
                .environment(AppState.shared.session))
            panel = p; didSetup = true
        }
        panel?.show(nearMouse: true)
    }

    func showHistoryWorkspace() {
        let s = AppState.shared
        s.resetForNew(text: "")
        showFloatingPanel()
    }

    private func fire(text: String?, context: CapturedContext? = nil) {
        let s = AppState.shared
        s.resetForNew(text: text ?? "")
        showFloatingPanel()
        if let text, !text.isEmpty { s.translate(context: context) }
    }

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "has_completed_onboarding") else { return }
        let contentView = OnboardingView { [weak self] in
            self?.dismissOnboarding()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "欢迎使用 OmniTrans"
        window.contentView = NSHostingView(rootView: contentView)
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
