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
            MenubarIconView(isTranslating: state.isTranslating)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Breathing animated menubar icon — subtly pulses when translating.
private struct MenubarIconView: View {
    @AppStorage("animations_enabled") private var animationsEnabled = true
    let isTranslating: Bool
    @State private var breathing = false

    private var nsImage: NSImage {
        if let path = Bundle.main.path(forResource: "menubar", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            icon.isTemplate = true
            icon.size = NSSize(width: 20, height: 20)
            return icon
        }
        return NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: nil)!
    }

    var body: some View {
        ZStack {
            if isTranslating {
                // Breathing ring behind the icon
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(breathing ? 360 : 0))
                    .frame(width: 22, height: 22)
                    .animation(animationsEnabled ? .linear(duration: 1.8).repeatForever(autoreverses: false) : nil, value: breathing)
                    .onAppear { breathing = true }
                    .onDisappear { breathing = false }
            }
            Image(nsImage: nsImage)
                .opacity(isTranslating ? (breathing ? 0.6 : 0.9) : 1.0)
                .animation(animationsEnabled ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil, value: breathing)
        }
        .onChange(of: isTranslating) { _, translating in
            breathing = translating
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var didSetup = false
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mode = UserDefaults.standard.string(forKey: "app_appearance") ?? "system"
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
        HotkeyManager.shared.onHotkey = { [weak self] text in
            self?.fire(text: text)
        }
        AnimationGate.refresh()
        HotkeyManager.shared.register()

        HotkeyManager.shared.onOCRHotkey = { [weak self] in
            self?.startOCRSelection()
        }
        HotkeyManager.shared.registerOCR()

        HotkeyManager.shared.onReplaceHotkey = { [weak self] in
            let text = AppState.shared.translatedText
            guard !text.isEmpty else { return }
            TextReplacementService.shared.replaceSelectedText(with: text)
        }
        HotkeyManager.shared.registerReplace()

        if UserDefaults.standard.bool(forKey: "clipboard_monitor") {
            ClipboardMonitor.shared.start()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showOnboardingIfNeeded()
        }

        // Right-click on menu bar icon also opens the popover
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            if let w = event.window, String(describing: type(of: w)).contains("StatusBar") {
                // Post a leftMouseDown to trigger MenuBarExtra's normal action
                if let btn = w.contentView?.hitTest(event.locationInWindow) {
                    btn.mouseDown(with: NSEvent.mouseEvent(
                        with: .leftMouseDown,
                        location: event.locationInWindow,
                        modifierFlags: [], timestamp: 0,
                        windowNumber: event.windowNumber,
                        context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1
                    ) ?? event)
                }
                return nil // consume right-click
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
        HotkeyManager.shared.unregisterOCR()
        HotkeyManager.shared.unregisterReplace()
        ClipboardMonitor.shared.stop()
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
