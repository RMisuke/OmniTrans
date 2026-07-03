import SwiftUI
import Carbon

// MARK: - General Settings View

struct GeneralSettingsView: View {
    @ObservedObject var state: AppState
    @AppStorage("dismiss_mode")     private var dismissMode      = "clickOutside"
    @AppStorage("clipboard_monitor") private var clipboardMonitor = false
    @AppStorage("panel_size")        private var panelSize        = "default"
    @AppStorage("app_appearance")    private var appAppearance    = "system"
    @AppStorage("animations_enabled") private var animationsEnabled = true

    // Shortcut recording state
    @State private var recTranslate = false
    @State private var recTranslateLabel = ""
    @State private var recTranslateMon: Any? = nil

    @State private var recOCR = false
    @State private var recOCRLabel = ""
    @State private var recOCRMon: Any? = nil

    @State private var recReplace = false
    @State private var recReplaceLabel = ""
    @State private var recReplaceMon: Any? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Shortcuts ──
                settingsCard(title: "快捷键", icon: "keyboard") {
                    shortcutRow(
                        title: "划词翻译",
                        desc: "选中文本后按下快捷键触发翻译",
                        label: HotkeyManager.hotkeyLabel(),
                        isRecording: $recTranslate,
                        labelFeedback: recTranslateLabel,
                        onStart: startTranslate, onStop: stopTranslate
                    )
                    Divider()
                    shortcutRow(
                        title: "框选 OCR",
                        desc: "框选屏幕区域进行文字识别翻译",
                        label: HotkeyManager.ocrHotkeyLabel(),
                        isRecording: $recOCR,
                        labelFeedback: recOCRLabel,
                        onStart: startOCR, onStop: stopOCR
                    )
                    Divider()
                    shortcutRow(
                        title: "原位替换",
                        desc: "将翻译结果直接粘贴到光标位置",
                        label: HotkeyManager.replaceHotkeyLabel(),
                        isRecording: $recReplace,
                        labelFeedback: recReplaceLabel,
                        onStart: startReplace, onStop: stopReplace
                    )
                    Divider()
                    HStack {
                        Spacer()
                        Button(action: resetShortcuts) {
                            Label("恢复全部默认", systemImage: "arrow.counterclockwise").font(.caption)
                        }
                        .buttonStyle(.borderless).foregroundColor(.secondary)
                    }
                }

                // ── Appearance ──
                settingsCard(title: "外观", icon: "paintbrush") {
                    HStack {
                        Text("主题模式").font(.subheadline)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { appAppearance },
                            set: { m in appAppearance = m; applyAppearance(m) }
                        )) {
                            Text("浅色").tag("light")
                            Text("深色").tag("dark")
                            Text("跟随系统").tag("system")
                        }
                        .pickerStyle(.segmented).frame(width: 240)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $animationsEnabled) {
                            Text("动画效果").font(.subheadline)
                        }
                        .onChange(of: animationsEnabled) { _, _ in AnimationGate.refresh() }
                        Text("关闭后将禁用所有界面动画，包括成功脉冲、骨架屏加载、窗口弹性缩放等")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // ── Behaviour ──
                settingsCard(title: "行为", icon: "slider.horizontal.3") {
                    Toggle(isOn: Binding(
                        get: { clipboardMonitor },
                        set: { v in
                            clipboardMonitor = v
                            UserDefaults.standard.set(v, forKey: "clipboard_monitor")
                            v ? ClipboardMonitor.shared.start() : ClipboardMonitor.shared.stop()
                        }
                    )) {
                        Text("剪贴板监听").font(.subheadline)
                        Text("自动翻译复制的内容").font(.caption).foregroundColor(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("关闭窗口").font(.subheadline)
                        Picker("", selection: $dismissMode) {
                            Text("点击窗口外").tag("clickOutside")
                            Text("手动关闭").tag("manual")
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("悬浮窗尺寸").font(.subheadline)
                        Picker("", selection: $panelSize) {
                            Text("小").tag("small")
                            Text("默认").tag("default")
                            Text("大").tag("large")
                            Text("动态").tag("dynamic")
                        }
                        .pickerStyle(.segmented).frame(width: 300)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Card wrapper

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(.secondary)
                Text(title).font(.headline).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(10)
        }
    }

    // MARK: - Shortcut row

    @ViewBuilder
    private func shortcutRow(
        title: String, desc: String, label: String,
        isRecording: Binding<Bool>, labelFeedback: String,
        onStart: @escaping () -> Void, onStop: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                keycaps(label)
                if isRecording.wrappedValue {
                    Text("按下快捷键…").font(.caption).foregroundColor(.accentColor)
                }
                Button(isRecording.wrappedValue ? "取消" : "修改") {
                    isRecording.wrappedValue ? onStop() : onStart()
                }
                .buttonStyle(.bordered).controlSize(.small).frame(width: 46)
            }
        }
        if !labelFeedback.isEmpty {
            Text("✓ \(labelFeedback)")
                .font(.caption).foregroundColor(.green)
        }
    }

    // MARK: - Keycap rendering

    @ViewBuilder
    private func keycaps(_ label: String) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(label.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 3).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
                    )
            }
        }
    }

    // MARK: - Reset

    private func resetShortcuts() {
        HotkeyManager.shared.resetToDefault()
        HotkeyManager.shared.resetOCRToDefault()
        HotkeyManager.shared.resetReplaceToDefault()
        recTranslateLabel = "已恢复"; recOCRLabel = "已恢复"; recReplaceLabel = "已恢复"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            recTranslateLabel = ""; recOCRLabel = ""; recReplaceLabel = ""
        }
    }

    // MARK: - Recording (translate)

    private func startTranslate() {
        recTranslate = true; recTranslateLabel = ""
        recTranslateMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard self.recTranslate else { return e }
            self.handleRec(e, label: &self.recTranslateLabel, onSet: { k, m in
                HotkeyManager.shared.reregister(carbonKey: k, carbonMods: m)
            })
            return nil
        }
    }
    private func stopTranslate() {
        recTranslate = false
        if let m = recTranslateMon { NSEvent.removeMonitor(m); recTranslateMon = nil }
    }

    // MARK: - Recording (OCR)

    private func startOCR() {
        recOCR = true; recOCRLabel = ""
        recOCRMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard self.recOCR else { return e }
            self.handleRec(e, label: &self.recOCRLabel, onSet: { k, m in
                HotkeyManager.shared.reregisterOCR(carbonKey: k, carbonMods: m)
            })
            return nil
        }
    }
    private func stopOCR() {
        recOCR = false
        if let m = recOCRMon { NSEvent.removeMonitor(m); recOCRMon = nil }
    }

    // MARK: - Recording (Replace)

    private func startReplace() {
        recReplace = true; recReplaceLabel = ""
        recReplaceMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard self.recReplace else { return e }
            self.handleRec(e, label: &self.recReplaceLabel, onSet: { k, m in
                HotkeyManager.shared.reregisterReplace(carbonKey: k, carbonMods: m)
            })
            return nil
        }
    }
    private func stopReplace() {
        recReplace = false
        if let m = recReplaceMon { NSEvent.removeMonitor(m); recReplaceMon = nil }
    }

    // MARK: - Shared recording logic

    private func handleRec(_ e: NSEvent, label: inout String, onSet: (Int, Int) -> Void) {
        let k = Int(e.keyCode)
        let m = HotkeyManager.carbonMods(from: e.modifierFlags)
        guard m != 0 else { label = "需要修饰键"; return }
        label = HotkeyManager.hotkeyLabelFrom(carbonKey: k, carbonMods: Int(m))
        onSet(k, Int(m))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            stopTranslate(); stopOCR(); stopReplace()
        }
    }

    // MARK: - Appearance

    private func applyAppearance(_ m: String) {
        switch m {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }
}
