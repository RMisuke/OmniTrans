import SwiftUI
import Carbon

/// Root view — "Solid Bottom Bar, Thick Content Canvas".
///
/// - **Solid Bottom**: opaque `windowBackgroundColor` with crisp 0.5pt
///   top hairline for hotkey labels.
/// - **Thick Canvas**: `TranslationView` uses the native thick material
///   background for a premium desktop feel.
struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var showSettings = false

    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(state: state, isPresented: $showSettings)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                VStack(spacing: 0) {
                    TranslationView(state: state, showSettings: $showSettings)
                        .environment(AppState.shared.session)
                    bottomBar
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(minWidth: 480, idealWidth: 480, minHeight: 500, idealHeight: 500)
        .background(AppTheme.bgSolid)
        .animation(AppTheme.Motion.fluid.gated, value: showSettings)
        .transaction { t in
            if !AnimationGate.isEnabled { t.disablesAnimations = true; t.animation = nil }
        }
        .onAppear { AnimationGate.refresh() }
        .onDisappear { Task { await TTSManager.shared.stop() }; MemoryPurgeHelper.shared.purgeBackendCache() }
    }

    // MARK: - Solid Bottom Bar

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "keyboard").font(.caption2).foregroundColor(AppTheme.accentAction)
                keycapView(HotkeyManager.hotkeyLabel())
                Text("划词翻译").font(.caption2).foregroundColor(AppTheme.textPrimary)
                Text("·").font(.caption2).foregroundColor(AppTheme.textSecondary)
                keycapView(HotkeyManager.ocrHotkeyLabel())
                Text("框选 OCR").font(.caption2).foregroundColor(AppTheme.textPrimary)
                Text("·").font(.caption2).foregroundColor(AppTheme.textSecondary)
                keycapView(HotkeyManager.replaceHotkeyLabel())
                Text("原位替换").font(.caption2).foregroundColor(AppTheme.textPrimary)
            }
            .help("翻译: \(HotkeyManager.hotkeyLabel())  |  OCR: \(HotkeyManager.ocrHotkeyLabel())  |  替换: \(HotkeyManager.replaceHotkeyLabel())")
            Spacer()
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack(spacing: 2) { Image(systemName: "power"); Text("退出") }.font(.caption2).foregroundColor(AppTheme.textSecondary)
            }.buttonStyle(.borderless).help("退出 OmniTrans").keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, AppTheme.spaceSM).padding(.vertical, 5)
        .background(AppTheme.bgSolid)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
        }
    }

    private func keycapView(_ label: String) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(label.enumerated()), id: \.offset) { _, ch in
                Text(String(ch)).keycapStyle()
            }
        }
    }
}
