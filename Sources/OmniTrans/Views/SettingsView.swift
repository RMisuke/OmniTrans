import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    @State private var showTemplates = false
    @State private var selectedTab = 0
    @State private var isRecordingShortcut = false
    @State private var recordedKeyLabel: String = ""
    @State private var localEventMonitor: Any? = nil
    @AppStorage("dismiss_mode") private var dismissMode = "clickOutside"
    @AppStorage("clipboard_monitor") private var clipboardMonitor = false
    @State private var shortcutRefreshToggle = false
    @State private var isRecordingOCRShortcut = false
    @State private var recordedOCRKeyLabel: String = ""
    @State private var ocrLocalEventMonitor: Any? = nil
    @State private var ocrShortcutRefreshToggle = false
    @AppStorage("max_history_count") private var maxHistoryCount = 100
    @State private var maxHistoryText: String = "100"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { isPresented = false }) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("返回翻译") }
                }.buttonStyle(.borderless)
                Spacer()
                Picker("", selection: $selectedTab) {
                    Text("API 配置").tag(0)
                    Text("通用").tag(1)
                    Text("历史").tag(2)
                    Text("关于").tag(3)
                }.pickerStyle(.segmented).frame(width: 260)
                Spacer()
                Text("v\(kAppVersion)").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal).padding(.top, 10).padding(.bottom, 8)

            Divider()

            switch selectedTab {
            case 0: apiTab
            case 1: generalTab
            case 2: historyTab
            case 3: aboutTab
            default: EmptyView()
            }
        }
    }

    // MARK: - API Tab

    private var apiTab: some View {
        Group {
            if showTemplates {
                templatePage
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button(action: { showTemplates = true }) { Label("模板", systemImage: "rectangle.stack.badge.plus") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button(action: addBlank) { Label("添加", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }.padding(.horizontal).padding(.vertical, 6)

                    if state.providers.isEmpty {
                        emptyProvidersView
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(state.providers) { p in
                                    providerCardWithSelection(p)
                                }
                            }.padding()
                        }
                    }
                }
            }
        }
    }

    private func providerCardWithSelection(_ p: APIProvider) -> some View {
        let isSelected = p.id == state.selectedProviderID && p.isEnabled
        return HStack(spacing: 0) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
            ProviderCardView(provider: p, allEnabled: state.enabledProviders,
                onUpdate: { updated in
                    state.updateProvider(updated)
                },
                onDelete: { state.deleteProvider($0) },
                onLoadKey: { KeychainManager.get(key: $0.uuidString) ?? "" }
            )
            .padding(.leading, isSelected ? 8 : 0)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
                    .padding(.leading, isSelected ? 8 : 0)
            )
        }
    }

    private var emptyProvidersView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
            }
            VStack(spacing: 6) {
                Text("连接 AI 开始翻译")
                    .font(.title3).bold()
                Text("支持 OpenAI、Claude、Gemini 及国内主流大模型")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text("API Key 安全存储在系统钥匙串中")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 16) {
                Button(action: { showTemplates = true }) {
                    Label("快速配置", systemImage: "bolt.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return)
                Button(action: addBlank) {
                    Label("手动添加", systemImage: "slider.horizontal.3")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("快捷键").font(.headline)

                    // ── Translate hotkey ──
                    HStack {
                        Text("划词翻译").font(.caption).bold().foregroundColor(.accentColor)
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        shortcutKeycaps(label: isRecordingShortcut ? (recordedKeyLabel.isEmpty ? "按下组合键..." : recordedKeyLabel) : HotkeyManager.hotkeyLabel())
                            .id(shortcutRefreshToggle)
                            .opacity(isRecordingShortcut ? 0.6 : 1.0)

                        if isRecordingShortcut {
                            ProgressView().scaleEffect(0.6)
                            Text("正在录制...").font(.caption2).foregroundColor(.accentColor)
                        }
                    }

                    HStack(spacing: 8) {
                        if isRecordingShortcut {
                            Button("取消录制") { stopTranslateRecording() }
                                .buttonStyle(.borderless).foregroundColor(.secondary)
                        } else {
                            Button(action: startTranslateRecording) {
                                Label("录制", systemImage: "record.circle")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }

                        Button(action: {
                            HotkeyManager.shared.resetToDefault()
                            recordedKeyLabel = ""
                            shortcutRefreshToggle.toggle()
                        }) {
                            Label("还原默认 (⌥D)", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                        .disabled(isRecordingShortcut)
                    }

                    Divider().padding(.vertical, 4)

                    // ── OCR hotkey ──
                    HStack {
                        Text("OCR 框选").font(.caption).bold().foregroundColor(.accentColor)
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        shortcutKeycaps(label: isRecordingOCRShortcut ? (recordedOCRKeyLabel.isEmpty ? "按下组合键..." : recordedOCRKeyLabel) : HotkeyManager.ocrHotkeyLabel())
                            .id(ocrShortcutRefreshToggle)
                            .opacity(isRecordingOCRShortcut ? 0.6 : 1.0)

                        if isRecordingOCRShortcut {
                            ProgressView().scaleEffect(0.6)
                            Text("正在录制...").font(.caption2).foregroundColor(.accentColor)
                        }
                    }

                    HStack(spacing: 8) {
                        if isRecordingOCRShortcut {
                            Button("取消录制") { stopOCRRecording() }
                                .buttonStyle(.borderless).foregroundColor(.secondary)
                        } else {
                            Button(action: startOCRRecording) {
                                Label("录制", systemImage: "record.circle")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }

                        Button(action: {
                            HotkeyManager.shared.resetOCRToDefault()
                            recordedOCRKeyLabel = ""
                            ocrShortcutRefreshToggle.toggle()
                        }) {
                            Label("还原默认 (⌥F)", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                        .disabled(isRecordingOCRShortcut)
                    }

                    Text("支持 ⌘/⌥/⌃/⇧ + 字母/数字/符号/F1-F12")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Divider()

                Group {
                    Text("默认语言").font(.headline)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("默认目标语言").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $state.targetLang) {
                                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in
                                    Text(l.rawValue).tag(l)
                                }
                            }.pickerStyle(.menu).frame(width: 120)
                        }
                        VStack(alignment: .leading) {
                            Text("默认源语言").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $state.sourceLang) {
                                ForEach(TranslationLanguage.allCases) { l in Text(l.rawValue).tag(l) }
                            }.pickerStyle(.menu).frame(width: 120)
                        }
                    }
                }

                Divider()

                Group {
                    Text("悬浮窗").font(.headline)
                    Picker("关闭方式", selection: $dismissMode) {
                        Text("点击外部自动关闭").tag("clickOutside")
                        Text("仅 Esc 关闭").tag("escOnly")
                    }.pickerStyle(.radioGroup)
                }

                Divider()

                Group {
                    Text("剪贴板监听").font(.headline)
                    Toggle("复制文本后自动弹出翻译", isOn: $clipboardMonitor)
                        .onChange(of: clipboardMonitor) { _, v in
                            if v { ClipboardMonitor.shared.start() } else { ClipboardMonitor.shared.stop() }
                        }
                    Text("开启后，在任何应用中使用 Cmd+C 复制文本即自动翻译")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Divider()

                Group {
                    Text("翻译历史").font(.headline)
                    HStack(spacing: 8) {
                        Text("最大记录数").font(.caption)
                        TextField("", text: $maxHistoryText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onChange(of: maxHistoryText) { _, v in
                                if let n = Int(v.trimmingCharacters(in: .whitespaces)), n >= 10, n <= 500 {
                                    maxHistoryCount = n
                                }
                            }
                            .onSubmit {
                                if let n = Int(maxHistoryText.trimmingCharacters(in: .whitespaces)) {
                                    if n < 10 { maxHistoryText = "10"; maxHistoryCount = 10 }
                                    else if n > 500 { maxHistoryText = "500"; maxHistoryCount = 500 }
                                    else { maxHistoryCount = n }
                                } else {
                                    maxHistoryText = String(maxHistoryCount)
                                }
                            }
                        Stepper("", value: Binding(
                            get: { Int(maxHistoryText) ?? maxHistoryCount },
                            set: { v in maxHistoryText = String(v); maxHistoryCount = v }
                        ), in: 10...500)
                            .frame(width: 20)
                        Text("(10–500)").font(.caption2).foregroundColor(.secondary)
                    }
                    Text("超出上限后自动清除最早的记录")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - History Tab

    private var historyTab: some View {
        VStack(spacing: 0) {
            if state.translationHistory.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: 64, height: 64)
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                    }
                    Text("暂无翻译记录").font(.title3).foregroundColor(.secondary)
                    Text("翻译后会自动记录在此，点击可恢复")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Spacer()
                    Button(action: { state.clearHistory() }) {
                        Label("清空", systemImage: "trash").font(.caption2)
                    }.buttonStyle(.borderless).foregroundColor(.red)
                }.padding(.horizontal).padding(.top, 6)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.translationHistory) { entry in
                            historyRow(entry)
                            if entry.id != state.translationHistory.last?.id {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(entry.sourceLang == .auto ? "自动" : entry.sourceLang.rawValue) → \(entry.targetLang.rawValue)")
                    .font(.caption2).foregroundColor(.accentColor)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.1)).cornerRadius(3)
                Text(entry.providerName).font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(entry.timestamp, style: .relative).font(.caption2).foregroundColor(.secondary)
            }
            Text(entry.input)
                .font(.caption2).foregroundColor(.primary).lineLimit(2)
            Text(entry.output)
                .font(.caption).foregroundColor(.primary).lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            state.inputText = entry.input
            state.translatedText = entry.output
            state.sourceLang = entry.sourceLang
            state.targetLang = entry.targetLang
            isPresented = false
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                ZStack {
                if let icon = NSImage(contentsOfFile: Bundle.main.path(forResource: "icon", ofType: "icns") ?? "") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .cornerRadius(18)
                } else if let icon = NSImage(contentsOfFile: Bundle.main.path(forResource: "icon", ofType: "png") ?? "") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .cornerRadius(18)
                } else {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 80, height: 80)
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 40)).foregroundColor(.accentColor)
                }
            }
            Text("OmniTrans").font(.title).bold()
            Text("版本 \(kAppVersion)").font(.subheadline).foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("基于大语言模型的多语种划词翻译工具").font(.caption).foregroundColor(.secondary)
                Text("• 支持 OpenAI / Claude / Gemini / 本地模型").font(.caption2).foregroundColor(.secondary)
                Text("• 全局快捷键划词翻译，悬浮窗显示结果").font(.caption2).foregroundColor(.secondary)
                Text("• 12 个预设 API 模板，一键配置").font(.caption2).foregroundColor(.secondary)
                Text("• 所有 API Key 安全存储于系统钥匙串").font(.caption2).foregroundColor(.secondary)
            }.multilineTextAlignment(.center)

            // Debug: reset onboarding flag for testing
            VStack(spacing: 6) {
                Divider()
                HStack {
                    Image(systemName: "arrow.counterclockwise").font(.caption2).foregroundColor(.secondary)
                    Text("开发者测试").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                }
                Button {
                    UserDefaults.standard.removeObject(forKey: "has_completed_onboarding")
                } label: {
                    Label("重置首次启动引导", systemImage: "restart.circle")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("下次启动将重新显示引导窗口")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)

                Spacer()
                Text("macOS 14+  ·  SwiftUI  ·  Bob-style").font(.caption2).foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Template page (inline, not sheet)

    private var templatePage: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { showTemplates = false }) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("返回") }
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("选择 API 模板").font(.headline)
                Spacer()
                Text("").frame(width: 60) // spacer for centering
            }
            .padding(.horizontal).padding(.top, 10).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ProviderTemplate.all) { t in
                        Button(action: { addTemplate(t) }) {
                            HStack(spacing: 10) {
                                Image(systemName: t.icon)
                                    .frame(width: 28)
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.body).foregroundColor(.primary)
                                    Text(t.desc).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(t.model)
                                    .font(.caption2).foregroundColor(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary).cornerRadius(4)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if t.id != ProviderTemplate.all.last?.id {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
            Text("所有模板均使用标准协议").font(.caption2).foregroundColor(.secondary).padding(.vertical, 8)
        }
    }

    private func addBlank() { let p = APIProvider.blank(); state.addProvider(p) }    // MARK: - Shortcut keycap display

    private func shortcutKeycaps(label: String) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(label.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 3).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                    )
            }
        }
    }

    // MARK: - Shortcut recording

    // ── Translate hotkey recording ──

    private func startTranslateRecording() {
        isRecordingShortcut = true
        recordedKeyLabel = ""

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecordingShortcut else { return event }
            self.handleTranslateRecordedKey(event: event)
            return nil
        }
    }

    private func stopTranslateRecording() {
        isRecordingShortcut = false
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func handleTranslateRecordedKey(event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let mods = HotkeyManager.carbonMods(from: event.modifierFlags)
        guard mods != 0 else {
            recordedKeyLabel = "需要至少一个修饰键"
            return
        }
        recordedKeyLabel = HotkeyManager.hotkeyLabelFrom(carbonKey: keyCode, carbonMods: Int(mods))
        HotkeyManager.shared.reregister(carbonKey: keyCode, carbonMods: Int(mods))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.stopTranslateRecording()
        }
    }

    // ── OCR hotkey recording ──

    private func startOCRRecording() {
        isRecordingOCRShortcut = true
        recordedOCRKeyLabel = ""

        ocrLocalEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecordingOCRShortcut else { return event }
            self.handleOCRRecordedKey(event: event)
            return nil
        }
    }

    private func stopOCRRecording() {
        isRecordingOCRShortcut = false
        if let monitor = ocrLocalEventMonitor {
            NSEvent.removeMonitor(monitor)
            ocrLocalEventMonitor = nil
        }
    }

    private func handleOCRRecordedKey(event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let mods = HotkeyManager.carbonMods(from: event.modifierFlags)
        guard mods != 0 else {
            recordedOCRKeyLabel = "需要至少一个修饰键"
            return
        }
        recordedOCRKeyLabel = HotkeyManager.hotkeyLabelFrom(carbonKey: keyCode, carbonMods: Int(mods))
        HotkeyManager.shared.reregisterOCR(carbonKey: keyCode, carbonMods: Int(mods))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.stopOCRRecording()
        }
    }

    private func addTemplate(_ t: ProviderTemplate) {
        var p = APIProvider.blank(kind: t.kind); p.name = t.name; p.baseURL = t.baseURL; p.modelName = t.model
        state.addProvider(p); showTemplates = false
    }
}
