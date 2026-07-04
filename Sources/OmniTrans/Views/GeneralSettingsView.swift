import SwiftUI
import Carbon
import ServiceManagement
import OSLog

/// General preferences — native macOS card styling with Action Blue accent.
struct GeneralSettingsView: View {
    @ObservedObject var state: AppState
    @AppStorage("dismiss_mode")        private var dismissMode       = "clickOutside"
    @AppStorage("clipboard_monitor")   private var clipboardMonitor  = false
    @AppStorage("panel_size")          private var panelSize         = "default"
    @AppStorage("app_appearance")      private var appAppearance     = "system"
    @AppStorage("animations_enabled")  private var animationsEnabled = true

    @State private var recTranslate = false; @State private var recTranslateLabel = ""; @State private var recTranslateMon: Any? = nil
    @State private var recOCR = false; @State private var recOCRLabel = ""; @State private var recOCRMon: Any? = nil
    @State private var recReplace = false; @State private var recReplaceLabel = ""; @State private var recReplaceMon: Any? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(title: "快捷键", icon: "keyboard") {
                    shortcutRow(title: "划词翻译", desc: "选中文本后按下快捷键触发翻译", label: HotkeyManager.hotkeyLabel(), isRecording: $recTranslate, labelFeedback: recTranslateLabel, onStart: startTranslate, onStop: stopTranslate)
                    Divider()
                    shortcutRow(title: "框选 OCR", desc: "框选屏幕区域进行文字识别翻译", label: HotkeyManager.ocrHotkeyLabel(), isRecording: $recOCR, labelFeedback: recOCRLabel, onStart: startOCR, onStop: stopOCR)
                    Divider()
                    shortcutRow(title: "原位替换", desc: "将翻译结果直接粘贴到光标位置", label: HotkeyManager.replaceHotkeyLabel(), isRecording: $recReplace, labelFeedback: recReplaceLabel, onStart: startReplace, onStop: stopReplace)
                    Divider()
                    HStack { Spacer(); Button(action: resetShortcuts) { Label("恢复全部默认", systemImage: "arrow.counterclockwise").font(.caption) }.buttonStyle(.borderless).foregroundColor(.secondary) }
                }
                settingsCard(title: "外观", icon: "paintbrush") {
                    HStack {
                        Text("主题模式").font(.subheadline).foregroundColor(AppTheme.textPrimary); Spacer()
                        Picker("", selection: Binding(get: { appAppearance }, set: { m in appAppearance = m; applyAppearance(m) })) {
                            Text("浅色").tag("light"); Text("深色").tag("dark"); Text("跟随系统").tag("system")
                        }.pickerStyle(.segmented).frame(width: 240)
                    }
                    Divider()
                    toggleRow(title: "动画效果", desc: "关闭后将禁用所有界面动画", isOn: $animationsEnabled, onChange: { AnimationGate.refresh() })
                    Divider()
                    launchAtLoginToggle
                }
                settingsCard(title: "行为", icon: "slider.horizontal.3") {
                    toggleRow(title: "剪贴板监听", desc: "自动翻译复制的内容", isOn: Binding(get: { clipboardMonitor }, set: { v in clipboardMonitor = v; UserDefaults.standard.set(v, forKey: "clipboard_monitor"); v ? ClipboardMonitor.shared.start() : ClipboardMonitor.shared.stop() }))
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("关闭窗口").font(.subheadline).foregroundColor(AppTheme.textPrimary)
                        Picker("", selection: $dismissMode) { Text("点击窗口外").tag("clickOutside"); Text("手动关闭").tag("manual") }.pickerStyle(.segmented).frame(width: 200)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("悬浮窗尺寸").font(.subheadline).foregroundColor(AppTheme.textPrimary)
                        Picker("", selection: $panelSize) { Text("小").tag("small"); Text("默认").tag("default"); Text("大").tag("large"); Text("动态").tag("dynamic") }.pickerStyle(.segmented).frame(width: 300)
                    }
                }
            }.padding(16)
        }
    }

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            HStack(spacing: 6) { Image(systemName: icon).foregroundColor(.secondary); Text(title).font(.headline).foregroundColor(AppTheme.textSecondary) }
            content()
        }.nativeCardStyle()
    }

    private func toggleRow(title: String, desc: String? = nil, isOn: Binding<Bool>, onChange: (() -> Void)? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundColor(AppTheme.textPrimary)
                if let desc { Text(desc).font(.caption).foregroundColor(AppTheme.textSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(AppTheme.accentAction)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { onChange?() }
        }
    }

    private func shortcutRow(title: String, desc: String, label: String, isRecording: Binding<Bool>, labelFeedback: String, onStart: @escaping () -> Void, onStop: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline).bold().foregroundColor(AppTheme.textPrimary); Text(desc).font(.caption).foregroundColor(AppTheme.textSecondary) }
                Spacer()
                HStack(spacing: 6) {
                    keycaps(label)
                    if isRecording.wrappedValue { Text("按下快捷键…").font(.caption).foregroundColor(AppTheme.accentAction) }
                    Button(isRecording.wrappedValue ? "取消" : "修改") { isRecording.wrappedValue ? onStop() : onStart() }.buttonStyle(.bordered).controlSize(.small).frame(width: 46)
                }
            }
            if !labelFeedback.isEmpty { Text("✓ \(labelFeedback)").font(.caption).foregroundColor(AppTheme.success) }
        }
    }

    private func keycaps(_ label: String) -> some View { HStack(spacing: 2) { ForEach(Array(label.enumerated()), id: \.offset) { _, ch in Text(String(ch)).keycapStyle() } } }

    private func resetShortcuts() {
        HotkeyManager.shared.resetToDefault(); HotkeyManager.shared.resetOCRToDefault(); HotkeyManager.shared.resetReplaceToDefault()
        recTranslateLabel = "已恢复"; recOCRLabel = "已恢复"; recReplaceLabel = "已恢复"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { recTranslateLabel = ""; recOCRLabel = ""; recReplaceLabel = "" }
    }

    private func startTranslate() { recTranslate = true; recTranslateLabel = ""; recTranslateMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in guard self.recTranslate else { return e }; self.handleRec(e, label: &self.recTranslateLabel, onSet: { k, m in HotkeyManager.shared.reregister(carbonKey: k, carbonMods: m) }); return nil } }
    private func stopTranslate() { recTranslate = false; if let m = recTranslateMon { NSEvent.removeMonitor(m); recTranslateMon = nil } }
    private func startOCR() { recOCR = true; recOCRLabel = ""; recOCRMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in guard self.recOCR else { return e }; self.handleRec(e, label: &self.recOCRLabel, onSet: { k, m in HotkeyManager.shared.reregisterOCR(carbonKey: k, carbonMods: m) }); return nil } }
    private func stopOCR() { recOCR = false; if let m = recOCRMon { NSEvent.removeMonitor(m); recOCRMon = nil } }
    private func startReplace() { recReplace = true; recReplaceLabel = ""; recReplaceMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in guard self.recReplace else { return e }; self.handleRec(e, label: &self.recReplaceLabel, onSet: { k, m in HotkeyManager.shared.reregisterReplace(carbonKey: k, carbonMods: m) }); return nil } }
    private func stopReplace() { recReplace = false; if let m = recReplaceMon { NSEvent.removeMonitor(m); recReplaceMon = nil } }
    private func handleRec(_ e: NSEvent, label: inout String, onSet: (Int, Int) -> Void) {
        let k = Int(e.keyCode); let m = HotkeyManager.carbonMods(from: e.modifierFlags)
        guard m != 0 else { label = "需要修饰键"; return }
        label = HotkeyManager.hotkeyLabelFrom(carbonKey: k, carbonMods: Int(m)); onSet(k, Int(m))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in stopTranslate(); stopOCR(); stopReplace() }
    }
    // MARK: - Launch at Login

    private var launchAtLoginToggle: some View {
        LaunchAtLoginRow()
    }

    private func applyAppearance(_ m: String) { switch m { case "light": NSApp.appearance = NSAppearance(named: .aqua); case "dark": NSApp.appearance = NSAppearance(named: .darkAqua); default: NSApp.appearance = nil } }
}

// MARK: - Launch at Login Row

/// macOS 13+ 原生登录项开关，使用 `SMAppService.mainApp`。
private struct LaunchAtLoginRow: View {
    @State private var isEnabled: Bool = false
    private let logger = Logger(subsystem: "com.omnitrans.app", category: "Settings")

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("开机自动启动")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textPrimary)
                Text("登录时自动在菜单栏启动 OmniTrans")
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in updateStatus(newValue) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(AppTheme.accentAction)
            .labelsHidden()
        }
        .onAppear {
            isEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func updateStatus(_ enable: Bool) {
        withAnimation(AppTheme.Motion.snip.gated) {
            isEnabled = enable
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if enable {
                    guard SMAppService.mainApp.status != .enabled else { return }
                    try SMAppService.mainApp.register()
                    logger.info("OmniTrans registered as login item.")
                } else {
                    guard SMAppService.mainApp.status == .enabled else { return }
                    try SMAppService.mainApp.unregister()
                    logger.info("OmniTrans unregistered as login item.")
                }
            } catch {
                logger.error("Failed to update login item: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    withAnimation(AppTheme.Motion.snip.gated) {
                        isEnabled = (SMAppService.mainApp.status == .enabled)
                    }
                }
            }
        }
    }
}
