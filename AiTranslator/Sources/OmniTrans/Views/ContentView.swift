import SwiftUI
import Carbon

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var showSettings = false

    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(state: state, isPresented: $showSettings)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    TranslationView(state: state, showSettings: $showSettings)
                    Divider()
                    bottomBar
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSettings)
        .frame(minWidth: 420, maxWidth: 700, minHeight: 460, maxHeight: 620)
    }

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "keyboard").font(.caption2).foregroundColor(.accentColor)
                keycapView
                Text("划词翻译").font(.caption2).foregroundColor(.secondary)
                Text("·").font(.caption2).foregroundColor(.secondary)
                ocrKeycapView
                Text("框选 OCR").font(.caption2).foregroundColor(.secondary)
            }
            .help("翻译: \(HotkeyManager.hotkeyLabel())  |  OCR 框选: \(HotkeyManager.ocrHotkeyLabel())")
            Spacer()
            Text("v\(kAppVersion)").font(.caption2).foregroundColor(.secondary)
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack(spacing: 2) { Image(systemName: "power"); Text("退出") }.font(.caption2)
            }.buttonStyle(.borderless).help("退出 OmniTrans").keyboardShortcut("q", modifiers: .command)
        }.padding(.horizontal, 12).padding(.vertical, 5)
    }

    // D3: Keycap-style hotkey label
    private var keycapView: some View {
        let label = HotkeyManager.hotkeyLabel()
        return HStack(spacing: 1) {
            ForEach(Array(label.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                    )
            }
        }
    }

    private var ocrKeycapView: some View {
        let label = HotkeyManager.ocrHotkeyLabel()
        return HStack(spacing: 1) {
            ForEach(Array(label.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                    )
            }
        }
    }
}
