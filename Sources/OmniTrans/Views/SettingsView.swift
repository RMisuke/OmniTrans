import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    @State private var selectedTab = 0
    @AppStorage("max_history_count") private var maxHistoryCount = 100
    @AppStorage("history_disabled") private var historyDisabled = false
    @AppStorage("custom_prompt_enabled") private var customPromptEnabled = false
    @AppStorage("custom_prompt_text") private var customPromptText = ""
    @State private var maxHistoryText: String = "100"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { isPresented = false }) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("返回") }
                }.buttonStyle(.borderless)
                Spacer()
                Picker("", selection: $selectedTab) {
                    Text("API 配置").tag(0)
                    Text("翻译").tag(1)
                    Text("通用").tag(2)
                    Text("历史").tag(3)
                    Text("关于").tag(4)
                }.pickerStyle(.segmented).frame(width: 310)
                Spacer()
                Text("v\(kAppVersion)").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal).padding(.top, 10).padding(.bottom, 8)

            Divider()

            switch selectedTab {
            case 0: APISettingsView(state: state)
            case 1: translateTab
            case 2: GeneralSettingsView(state: state)
            case 3: historyTab
            case 4: aboutTab
            default: EmptyView()
            }
        }
    }

    // MARK: - Translate Tab

    private var translateTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("词典查词默认模型", systemImage: "character.book.closed.fill")
                        .font(.headline)
                    Text("查单词时优先使用此模型。留空则使用当前选中的模型。")
                        .font(.caption).foregroundColor(.secondary)

                    if state.enabledProviders.isEmpty {
                        Text("暂无可用模型，请先在「API 配置」中添加")
                            .font(.caption).foregroundColor(.orange)
                    } else {
                        Picker("词典模型", selection: Binding(
                            get: { state.dictProviderID },
                            set: { id in state.dictProviderID = id; ProviderStorageManager.saveDictProviderID(id) }
                        )) {
                            Text("跟随当前选择").tag(nil as UUID?)
                            ForEach(state.enabledProviders) { p in
                                Text("\(p.name) · \(p.modelName)").tag(p.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu).frame(maxWidth: 320)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04)).cornerRadius(8)

                VStack(alignment: .leading, spacing: 8) {
                    Label("语言方向", systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("源语言").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $state.sourceLang) {
                                ForEach(TranslationLanguage.allCases) { l in Text(l.rawValue).tag(l) }
                            }.pickerStyle(.menu).frame(width: 120)
                        }
                        Image(systemName: "arrow.right").foregroundColor(.secondary).padding(.top, 14)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("目标语言").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $state.targetLang) {
                                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Text(l.rawValue).tag(l) }
                            }.pickerStyle(.menu).frame(width: 120)
                        }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04)).cornerRadius(8)

                // ── Custom prompt ──
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("自定义翻译提示词", systemImage: "text.append")
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: $customPromptEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    }
                    Text("支持变量 {sourceLang}、{targetLang}。优化提示词可提升翻译质量并降低 token 消耗。")
                        .font(.caption).foregroundColor(.secondary)

                    TextEditor(text: Binding(
                        get: {
                            // When enabled: show custom text. When disabled: sync with system default.
                            customPromptEnabled
                                ? (customPromptText.isEmpty ? defaultPrompt() : customPromptText)
                                : defaultPrompt()
                        },
                        set: { newValue in
                            if customPromptEnabled {
                                customPromptText = newValue
                            }
                            // When disabled, edits are rejected — always shows system default
                        }
                    ))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(6)
                    .opacity(customPromptEnabled ? 1.0 : 0.45)
                    .disabled(!customPromptEnabled)

                    Button(action: resetCustomPrompt) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("恢复默认提示词")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color.primary.opacity(0.04)).cornerRadius(8)
            }
            .padding()
        }
    }

    private func defaultPrompt() -> String {
        "You are a professional translator. Translate the following text to {targetLang} accurately and concisely. Preserve the original meaning, tone, and formatting. Output only the translation without any explanations, notes, or markdown fences."
    }

    private func resetCustomPrompt() {
        customPromptText = defaultPrompt()
    }

    // MARK: - History Tab

    private var historyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("翻译历史", systemImage: "clock.arrow.circlepath")
                    .font(.headline)

                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("最大保存条数").font(.caption).foregroundColor(.secondary)
                        TextField("", text: $maxHistoryText)
                            .frame(width: 50)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit {
                                if let v = Int(maxHistoryText), v > 0, v <= 500 {
                                    maxHistoryCount = v
                                } else {
                                    maxHistoryText = "\(maxHistoryCount)"
                                }
                            }
                            .onAppear { maxHistoryText = "\(maxHistoryCount)" }
                    }
                    Toggle("不保存历史", isOn: $historyDisabled)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .onChange(of: historyDisabled) { _, disabled in
                            if disabled { state.clearHistory() }
                        }
                    if !state.translationHistory.isEmpty {
                        Button(action: { state.clearHistory() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("一键清除")
                            }
                            .font(.caption)
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)

                if historyDisabled {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundColor(.secondary)
                        Text("历史记录已关闭").font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if state.translationHistory.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock").font(.system(size: 32)).foregroundColor(.secondary)
                        Text("暂无翻译记录").font(.subheadline).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    ForEach(state.translationHistory) { item in
                        Button(action: { restoreHistory(item) }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    // Provider badge
                                    Text(item.providerName)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.accentColor.opacity(0.1))
                                        )
                                    // Language direction
                                    HStack(spacing: 2) {
                                        Text(item.sourceLang.rawValue)
                                            .font(.system(size: 10)).foregroundColor(.secondary)
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 8)).foregroundColor(.secondary)
                                        Text(item.targetLang.rawValue)
                                            .font(.system(size: 10)).foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.primary.opacity(0.06))
                                    )
                                    Spacer()
                                    // Restore icon
                                    Image(systemName: "arrow.up.left.square")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                }
                                // Source text
                                Text(item.input)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                // Translated text
                                Text(item.output)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let iconPath = Bundle.main.path(forResource: "icon", ofType: "icns"),
                   let nsImage = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .cornerRadius(18)
                        .shadow(radius: 4)
                } else {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 48)).foregroundColor(.accentColor)
                }

                Text("OmniTrans").font(.title).bold()
                Text("版本 \(kAppVersion)").font(.subheadline).foregroundColor(.secondary)
                Text("AI 驱动的菜单栏翻译与查词工具")
                    .font(.caption).foregroundColor(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("功能特性").font(.headline)
                    FeatureRow(icon: "text.bubble", text: "划词翻译 — 选中文本后 \(HotkeyManager.hotkeyLabel()) 一键翻译")
                    FeatureRow(icon: "rectangle.dashed", text: "框选 OCR — \(HotkeyManager.ocrHotkeyLabel()) 截取任意区域文字识别并翻译")
                    FeatureRow(icon: "character.book.closed", text: "智能词典 — 自动检测单词，提供结构化释义与例句")
                    FeatureRow(icon: "globe", text: "多引擎支持 — OpenAI · Claude · Gemini · 通义千问 · DeepSeek 等")
                    FeatureRow(icon: "cpu", text: "本地离线 — macOS 原生词典 + 神经网络翻译引擎")
                    FeatureRow(icon: "lock.shield", text: "隐私优先 — 密钥本地 AES-256 加密存储，不上传任何第三方")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("快捷键").font(.headline)
                    Text("\(HotkeyManager.hotkeyLabel()) — 划词翻译").font(.caption).foregroundColor(.secondary)
                    Text("\(HotkeyManager.ocrHotkeyLabel()) — 框选 OCR").font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                Text("OmniTrans v\(kAppVersion) · 基于 SwiftUI 构建 · 2026")
                    .font(.caption2).foregroundColor(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("调试").font(.headline).foregroundColor(.secondary)
                    Button(action: {
                        UserDefaults.standard.set(false, forKey: "has_completed_onboarding")
                        let alert = NSAlert()
                        alert.messageText = "已重置引导页"
                        alert.informativeText = "下次启动时将重新显示首次使用引导。"
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "好的")
                        alert.runModal()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("重置首次使用引导")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    // MARK: - History restore

    private func restoreHistory(_ item: HistoryEntry) {
        state.inputText = item.input
        state.translatedText = item.output
        state.sourceLang = item.sourceLang
        state.targetLang = item.targetLang
        state.errorMessage = nil
        state.dictionaryEntry = nil
        // Switch to the provider that was used
        if let p = state.providers.first(where: { $0.name == item.providerName }) {
            state.selectedProviderID = p.id
            ProviderStorageManager.saveSelectedProviderID(p.id)
        }
        // Go back to main view
        isPresented = false
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 20).foregroundColor(.accentColor)
            Text(text).font(.caption)
        }
    }
}
