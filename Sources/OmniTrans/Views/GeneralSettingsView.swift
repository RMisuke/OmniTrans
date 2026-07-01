import SwiftUI
import Carbon

/// General settings: shortcut recording, appearance, clipboard monitor, dismiss mode.
struct GeneralSettingsView: View {
    @ObservedObject var state: AppState
    @AppStorage("dismiss_mode") private var dismissMode = "clickOutside"
    @AppStorage("clipboard_monitor") private var clipboardMonitor = false
    @State private var isRecordingShortcut = false
    @State private var recordedKeyLabel: String = ""
    @State private var localEventMonitor: Any? = nil
    @State private var isRecordingOCRShortcut = false
    @State private var recordedOCRKeyLabel: String = ""
    @State private var ocrLocalEventMonitor: Any? = nil

    private let cardBg = Color.primary.opacity(0.04)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ── Shortcuts section ──
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("快捷键", systemImage: "keyboard")
                            .font(.headline)
                        Spacer()
                        Button(action: resetShortcuts) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("恢复默认")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                        .help("恢复快捷键到默认设置")
                    }
                    .padding(.bottom, 4)

                    // Translate hotkey
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("划词翻译").font(.subheadline).bold()
                            Text("选中文本后按下快捷键触发翻译")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            shortcutKeycaps(label: HotkeyManager.hotkeyLabel())
                            if isRecordingShortcut {
                                Text("按下新快捷键…")
                                    .font(.caption).foregroundColor(.accentColor)
                            }
                            Button(isRecordingShortcut ? "取消" : "修改") {
                                if isRecordingShortcut { stopTranslateRecording() }
                                else { startTranslateRecording() }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .frame(width: 50)
                        }
                    }
                    if !recordedKeyLabel.isEmpty {
                        Text("已设置为 \(recordedKeyLabel)")
                            .font(.caption).foregroundColor(.green).transition(.opacity)
                    }

                    Divider()

                    // OCR hotkey
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("框选 OCR").font(.subheadline).bold()
                            Text("框选屏幕任意区域进行文字识别翻译")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            shortcutKeycaps(label: HotkeyManager.ocrHotkeyLabel())
                            if isRecordingOCRShortcut {
                                Text("按下新快捷键…")
                                    .font(.caption).foregroundColor(.accentColor)
                            }
                            Button(isRecordingOCRShortcut ? "取消" : "修改") {
                                if isRecordingOCRShortcut { stopOCRRecording() }
                                else { startOCRRecording() }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .frame(width: 50)
                        }
                    }
                    if !recordedOCRKeyLabel.isEmpty {
                        Text("已设置为 \(recordedOCRKeyLabel)")
                            .font(.caption).foregroundColor(.green).transition(.opacity)
                    }
                }
                .padding(16)
                .background(cardBg).cornerRadius(10)

                // ── Appearance section ──
                VStack(alignment: .leading, spacing: 12) {
                    Label("外观", systemImage: "paintbrush")
                        .font(.headline)
                        .padding(.bottom, 4)

                    HStack {
                        Text("主题模式").font(.subheadline)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { UserDefaults.standard.string(forKey: "app_appearance") ?? "system" },
                            set: { mode in
                                UserDefaults.standard.set(mode, forKey: "app_appearance")
                                applyAppearance(mode)
                            }
                        )) {
                            Text("浅色").tag("light")
                            Text("深色").tag("dark")
                            Text("跟随系统").tag("system")
                        }
                        .pickerStyle(.segmented).frame(width: 260)
                    }
                }
                .padding(16)
                .background(cardBg).cornerRadius(10)

                // ── Behaviour section ──
                VStack(alignment: .leading, spacing: 12) {
                    Label("行为", systemImage: "slider.horizontal.3")
                        .font(.headline)
                        .padding(.bottom, 4)

                    Toggle(isOn: Binding(
                        get: { clipboardMonitor },
                        set: { v in
                            clipboardMonitor = v
                            UserDefaults.standard.set(v, forKey: "clipboard_monitor")
                            if v {
                                ClipboardMonitor.shared.start()
                            } else {
                                ClipboardMonitor.shared.stop()
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("剪贴板监听").font(.subheadline)
                            Text("自动翻译复制的内容").font(.caption).foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("悬浮窗关闭方式").font(.subheadline)
                        Picker("", selection: $dismissMode) {
                            Text("点击外部关闭").tag("clickOutside")
                            Text("仅 Esc 关闭").tag("escOnly")
                        }
                        .pickerStyle(.radioGroup)
                    }
                }
                .padding(16)
                .background(cardBg).cornerRadius(10)
            }
            .padding()
        }
    }

    // MARK: - Reset shortcuts

    private func resetShortcuts() {
        // Reset translate hotkey to ⌥D
        UserDefaults.standard.set(Int(kVK_ANSI_D), forKey: "hotkey_carbonKey")
        UserDefaults.standard.set(Int(optionKey), forKey: "hotkey_carbonMods")
        HotkeyManager.shared.reregister(carbonKey: Int(kVK_ANSI_D), carbonMods: Int(optionKey))

        // Reset OCR hotkey to ⌥F
        UserDefaults.standard.set(Int(kVK_ANSI_F), forKey: "ocr_hotkey_carbonKey")
        UserDefaults.standard.set(Int(optionKey), forKey: "ocr_hotkey_carbonMods")
        HotkeyManager.shared.reregisterOCR(carbonKey: Int(kVK_ANSI_F), carbonMods: Int(optionKey))

        recordedKeyLabel = "已恢复默认"
        recordedOCRKeyLabel = "已恢复默认"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            recordedKeyLabel = ""
            recordedOCRKeyLabel = ""
        }
    }

    // MARK: - Shortcut recording

    private func startTranslateRecording() {
        isRecordingShortcut = true; recordedKeyLabel = ""
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecordingShortcut else { return event }
            self.handleTranslateRecordedKey(event: event)
            return nil
        }
    }

    private func stopTranslateRecording() {
        isRecordingShortcut = false
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
    }

    private func handleTranslateRecordedKey(event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let mods = HotkeyManager.carbonMods(from: event.modifierFlags)
        guard mods != 0 else { recordedKeyLabel = "需要至少一个修饰键"; return }
        recordedKeyLabel = HotkeyManager.hotkeyLabelFrom(carbonKey: keyCode, carbonMods: Int(mods))
        HotkeyManager.shared.reregister(carbonKey: keyCode, carbonMods: Int(mods))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { stopTranslateRecording() }
    }

    private func startOCRRecording() {
        isRecordingOCRShortcut = true; recordedOCRKeyLabel = ""
        ocrLocalEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecordingOCRShortcut else { return event }
            self.handleOCRRecordedKey(event: event)
            return nil
        }
    }

    private func stopOCRRecording() {
        isRecordingOCRShortcut = false
        if let m = ocrLocalEventMonitor { NSEvent.removeMonitor(m); ocrLocalEventMonitor = nil }
    }

    private func handleOCRRecordedKey(event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let mods = HotkeyManager.carbonMods(from: event.modifierFlags)
        guard mods != 0 else { recordedOCRKeyLabel = "需要至少一个修饰键"; return }
        recordedOCRKeyLabel = HotkeyManager.hotkeyLabelFrom(carbonKey: keyCode, carbonMods: Int(mods))
        HotkeyManager.shared.reregisterOCR(carbonKey: keyCode, carbonMods: Int(mods))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { stopOCRRecording() }
    }

    // MARK: - Keycap

    private func shortcutKeycaps(label: String) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(label.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                    )
            }
        }
    }

    private func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }
}
