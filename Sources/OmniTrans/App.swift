import SwiftUI
import AppKit

@main
struct OmniTransApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(true)) {
            ContentView(state: state)
        } label: {
            Image(nsImage: menubarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menubarIcon: NSImage {
        if let path = Bundle.main.path(forResource: "menubar", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            icon.isTemplate = true
            icon.size = NSSize(width: 20, height: 20)
            return icon
        }
        return NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: nil)!
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var didSetup = false
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply saved appearance mode
        let mode = UserDefaults.standard.string(forKey: "app_appearance") ?? "system"
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
        HotkeyManager.shared.onHotkey = { [weak self] text in
            self?.fire(text: text)
        }
        HotkeyManager.shared.register()

        HotkeyManager.shared.onOCRHotkey = { [weak self] in
            self?.startOCRSelection()
        }
        HotkeyManager.shared.registerOCR()

        if UserDefaults.standard.bool(forKey: "clipboard_monitor") {
            ClipboardMonitor.shared.start()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showOnboardingIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
        HotkeyManager.shared.unregisterOCR()
        ClipboardMonitor.shared.stop()
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - OCR Selection

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
            p.setFrame(NSRect(x: 0, y: 0, width: 380, height: 380), display: false)
            p.contentView = NSHostingView(rootView: FloatingTranslationView(state: AppState.shared))
            panel = p; didSetup = true
        }
        panel?.show(nearMouse: true)
    }

    private func fire(text: String?) {
        let s = AppState.shared
        s.resetForNew(text: text ?? "")
        showFloatingPanel()
        if let text, !text.isEmpty { s.translate() }
    }

    // MARK: - Onboarding

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "has_completed_onboarding") else { return }

        let contentView = OnboardingView { [weak self] in
            self?.dismissOnboarding()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
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
