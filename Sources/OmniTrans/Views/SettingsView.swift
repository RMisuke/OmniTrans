import SwiftUI

// MARK: - Settings Root View

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    @State private var selectedTab = 0
    @State private var previousTab = 0
    @Namespace private var tabNamespace
    @AppStorage("max_history_count") private var maxHistoryCount = 100
    @AppStorage("history_disabled") private var historyDisabled = false
    @AppStorage("custom_prompt_enabled") private var customPromptEnabled = false
    @AppStorage("custom_prompt_text") private var customPromptText = ""
    @State private var maxHistoryText: String = "100"

    private let tabItems = [
        (title: "API 配置",   icon: "server.rack"),
        (title: "翻译",       icon: "arrow.triangle.2.circlepath"),
        (title: "通用",       icon: "gearshape"),
        (title: "历史",       icon: "clock.arrow.circlepath"),
        (title: "关于",       icon: "info.circle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            headerBar
            Divider()

            // ── Content ──
            contentArea
        }
        .frame(width: 480, height: 500)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 0) {
            Button(action: { withAnimationGated(.easeInOut(duration: 0.2)) { isPresented = false } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    Text("返回").font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)

            Spacer()

            // Centered tabs
            HStack(spacing: 2) {
                ForEach(Array(tabItems.enumerated()), id: \.offset) { idx, item in
                    tabButton(idx: idx, item: item)
                }
            }

            Spacer()

            // Version badge — invisible spacer to keep tabs centered
            Text("").font(.caption2).padding(.trailing, 16).hidden()
        }
        .padding(.vertical, 8)
    }

    private func tabButton(idx: Int, item: (title: String, icon: String)) -> some View {
        Button(action: {
            previousTab = selectedTab
            withAnimationGated(.spring(response: 0.28, dampingFraction: 0.8)) { selectedTab = idx }
        }) {
            HStack(spacing: 4) {
                Image(systemName: item.icon).font(.system(size: 10))
                Text(item.title)
                    .font(.system(size: 11, weight: selectedTab == idx ? .medium : .regular))
            }
            .foregroundColor(selectedTab == idx ? .white : Color(NSColor.controlTextColor))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
            .background(
                ZStack {
                    if selectedTab == idx {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "tabBg", in: tabNamespace)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content area

    private var contentArea: some View {
        ZStack {
            switch selectedTab {
            case 0: APISettingsView(state: state)
            case 1: translateSettingsTab
            case 2: GeneralSettingsView(state: state)
            case 3: historySettingsTab
            case 4: aboutSettingsTab
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(
            .asymmetric(
                insertion: .move(edge: selectedTab > previousTab ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: selectedTab > previousTab ? .leading : .trailing).combined(with: .opacity)
            )
        )
        .id(selectedTab)
    }

    // MARK: - Translate Settings Tab

    private var translateSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card(title: "词典查词默认模型", icon: "character.book.closed.fill") {
                    Text("查单词时优先使用的模型，留空则跟随当前选择")
                        .font(.caption).foregroundColor(.secondary)
                    if state.enabledProviders.isEmpty {
                        Text("暂无可用模型").font(.caption).foregroundColor(.orange)
                    } else {
                        Picker("", selection: Binding(
                            get: { state.dictProviderID },
                            set: { id in state.dictProviderID = id; ProviderStorageManager.saveDictProviderID(id) }
                        )) {
                            Text("跟随当前选择").tag(nil as UUID?)
                            ForEach(state.enabledProviders) { p in
                                Text("\(p.name) · \(p.modelName)").tag(p.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu).frame(maxWidth: 280)
                    }
                }

                card(title: "语言方向", icon: "arrow.left.arrow.right") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("源语言").font(.caption2).foregroundColor(.secondary)
                            Picker("", selection: $state.sourceLang) {
                                ForEach(TranslationLanguage.allCases) { l in Text(l.rawValue).tag(l) }
                            }.pickerStyle(.menu).frame(width: 110)
                        }
                        Image(systemName: "arrow.right").foregroundColor(.secondary).padding(.top, 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("目标语言").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $state.targetLang) {
                                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Text(l.rawValue).tag(l) }
                            }.pickerStyle(.menu).frame(width: 110)
                        }
                    }
                }

                card(title: "失败自动降级", icon: "arrow.triangle.branch") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("启用后当前 API 失败时按列表顺序尝试下一个")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "fallback_on_failure") },
                            set: { UserDefaults.standard.set($0, forKey: "fallback_on_failure") }
                        ))
                        .toggleStyle(.switch).controlSize(.small)
                    }
                }

                card(title: "自定义翻译提示词", icon: "text.append") {
                    HStack {
                        Text("支持 {sourceLang} / {targetLang} 变量").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Toggle("", isOn: $customPromptEnabled).toggleStyle(.switch).controlSize(.small)
                    }
                    TextEditor(text: Binding(
                        get: {
                            customPromptEnabled
                                ? (customPromptText.isEmpty ? defaultPrompt() : customPromptText)
                                : defaultPrompt()
                        },
                        set: { newValue in
                            if customPromptEnabled { customPromptText = newValue }
                        }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 130)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
                    .opacity(customPromptEnabled ? 1.0 : 0.4)
                    .disabled(!customPromptEnabled)
                    Button(action: resetCustomPrompt) {
                        Label("恢复默认", systemImage: "arrow.counterclockwise").font(.caption)
                    }
                    .buttonStyle(.borderless).foregroundColor(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - History Settings Tab

    private var historySettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("最大条数").font(.caption)
                        TextField("", text: $maxHistoryText)
                            .frame(width: 44)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onSubmit {
                                if let v = Int(maxHistoryText), v > 0, v <= 500 { maxHistoryCount = v }
                                else { maxHistoryText = "\(maxHistoryCount)" }
                            }
                            .onAppear { maxHistoryText = "\(maxHistoryCount)" }
                    }
                    Toggle("不保存", isOn: $historyDisabled).toggleStyle(.checkbox).font(.caption)
                        .onChange(of: historyDisabled) { _, d in if d { state.clearHistory() } }
                    if !state.translationHistory.isEmpty {
                        Button(action: { state.clearHistory() }) {
                            Label("清除全部", systemImage: "trash").font(.caption).foregroundColor(.red)
                        }.buttonStyle(.borderless)
                    }
                }
                .padding(12).background(Color.primary.opacity(0.04)).cornerRadius(8)

                if historyDisabled {
                    Text("历史记录已关闭").font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if state.translationHistory.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock").font(.title).foregroundColor(.secondary)
                        Text("暂无翻译记录").font(.subheadline).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    ForEach(state.translationHistory) { item in
                        Button(action: { restoreHistory(item) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.providerName).font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.1)).cornerRadius(3)
                                    Spacer()
                                    Text(item.timestamp, style: .relative).font(.caption2).foregroundColor(.secondary)
                                }
                                Text(item.input).font(.caption).lineLimit(1).foregroundColor(.primary)
                                Text(item.output).font(.caption).lineLimit(1).foregroundColor(.secondary)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.03)).cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .onAppear { state.loadFullHistory() }
        .onDisappear { state.trimHistory() }
    }

    // MARK: - About Tab

    private var aboutSettingsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let iconPath = Bundle.main.path(forResource: "icon", ofType: "icns"),
                   let nsImage = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: nsImage).resizable()
                        .frame(width: 72, height: 72).cornerRadius(16).shadow(radius: 4)
                } else {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 48)).foregroundColor(.accentColor)
                }

                Text("OmniTrans").font(.title2).bold()
                Text("v\(kAppVersion)").font(.subheadline).foregroundColor(.secondary)
                Text("菜单栏翻译 · 划词 · OCR · 词典 · TTS · 多引擎")
                    .font(.caption).foregroundColor(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    FeatureRow(icon: "text.bubble", text: "划词翻译 — \(HotkeyManager.hotkeyLabel()) 选中即译")
                    FeatureRow(icon: "rectangle.dashed", text: "OCR 框选 — \(HotkeyManager.ocrHotkeyLabel()) 框选屏幕取字")
                    FeatureRow(icon: "arrow.triangle.swap", text: "原位替换 — \(HotkeyManager.replaceHotkeyLabel()) 直接粘贴译文")
                    FeatureRow(icon: "character.book.closed", text: "智能词典 — 自动检测单词，结构化释义 + 音标 + 例句")
                    FeatureRow(icon: "speaker.wave.2", text: "TTS 朗读 — 翻译结果与词典词汇一键朗读")
                    FeatureRow(icon: "globe", text: "9 个引擎 — OpenAI · Claude · Gemini · 通义 · DeepSeek · 火山 · Google · Bing · 阿里")
                    FeatureRow(icon: "arrow.triangle.branch", text: "智能降级 — AI → MT → 原生引擎逐级回退，按 Provider 列表顺序重试")
                    FeatureRow(icon: "cpu", text: "原生引擎 — macOS 内置词典 + Translation API，零网络零 Token")
                    FeatureRow(icon: "text.quote", text: "场景预设 — 翻译 / 润色 / 口语 / 代码 / 文案 5 种 Prompt")
                    FeatureRow(icon: "rectangle.expand.vertical", text: "动态窗口 — 小 / 默认 / 大 / 动态 四种尺寸")
                    FeatureRow(icon: "rectangle.on.rectangle", text: "剪贴板监听 — 后台 0% CPU · NSWorkspace 通知驱动")
                    FeatureRow(icon: "arrow.up.arrow.down", text: "拖动排序 — API 配置卡片自由重排，持久化保存")
                    FeatureRow(icon: "lock.shield", text: "隐私 — AES-256-GCM 文件加密，密钥绑定 IOPlatformUUID")
                }
                Divider()

                Text("OmniTrans · SwiftUI · 零第三方依赖 · 2026")
                    .font(.caption2).foregroundColor(.secondary)

                Divider()

                Button(action: {
                    UserDefaults.standard.set(false, forKey: "has_completed_onboarding")
                    let a = NSAlert()
                    a.messageText = "已重置引导页"
                    a.informativeText = "下次启动时将重新显示首次使用引导。"
                    a.alertStyle = .informational
                    a.addButton(withTitle: "好的")
                    a.runModal()
                }) {
                    Label("重置首次使用引导", systemImage: "arrow.counterclockwise").font(.caption)
                }
                .buttonStyle(.borderless).foregroundColor(.secondary)
            }
            .padding()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func card<C: View>(title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline).bold()
            content()
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }

    private func defaultPrompt() -> String {
        "You are a professional translator. Translate the following text to {targetLang} accurately and concisely. Preserve the original meaning, tone, and formatting. Output only the translation without any explanations, notes, or markdown fences."
    }

    private func resetCustomPrompt() {
        customPromptText = defaultPrompt()
    }

    private func restoreHistory(_ item: HistoryEntry) {
        state.inputText = item.input
        state.translatedText = item.output
        state.sourceLang = item.sourceLang
        state.targetLang = item.targetLang
        state.errorMessage = nil
        state.dictionaryEntry = nil
        if let p = state.providers.first(where: { $0.name == item.providerName }) {
            state.selectedProviderID = p.id
            ProviderStorageManager.saveSelectedProviderID(p.id)
        }
        isPresented = false
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 18).foregroundColor(.accentColor).font(.caption)
            Text(text).font(.caption)
        }
    }
}
