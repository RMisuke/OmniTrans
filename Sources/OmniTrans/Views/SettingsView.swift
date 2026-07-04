import SwiftUI

/// Settings panel — "Solid Top Header, Thick Content Scroll".
///
/// - **Solid Header**: opaque `windowBackgroundColor` with 0.5pt hairline
///   divider — rock-solid baseline for tab controls.
/// - **Content**: scrollable body remains on the thick material canvas.
/// - **Accent**: Action Blue (#0066cc) for active tab and primary buttons.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    @State private var selectedTab = 0
    @Namespace private var tabNamespace
    @AppStorage("max_history_count") private var maxHistoryCount = 100
    @AppStorage("history_disabled") private var historyDisabled = false
    @AppStorage("custom_prompt_enabled") private var customPromptEnabled = false
    @AppStorage("custom_prompt_text") private var customPromptText = ""
    @AppStorage("is_context_aware") private var isContextAware = true
    @AppStorage("context_intensity") private var contextIntensity = 2
    @AppStorage("cache_enabled") private var cacheEnabled = true
    @State private var maxHistoryText: String = "100"

    // ── History search & expand state ──
    @State private var historySearchText: String = ""
    @State private var expandedHistoryItemId: UUID? = nil

    private let tabItems = [
        (title: "API 配置", icon: "server.rack"),
        (title: "翻译",    icon: "arrow.triangle.2.circlepath"),
        (title: "通用",    icon: "gearshape"),
        (title: "历史",    icon: "clock.arrow.circlepath"),
        (title: "关于",    icon: "info.circle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
        }
        .frame(width: 480, height: 500)
        .background(AppTheme.bgSolid)
    }

    // MARK: - Solid Header

    private var headerBar: some View {
        HStack(spacing: 0) {
            Button(action: { withAnimation(AppTheme.Motion.snip.gated) { isPresented = false } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    Text("返回").font(.system(size: 13))
                }
                .foregroundColor(AppTheme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.leading, 8)
            Spacer()
            HStack(spacing: 2) {
                ForEach(Array(tabItems.enumerated()), id: \.offset) { idx, item in tabButton(idx: idx, item: item) }
            }
            Spacer()
            Text("").font(.caption2).padding(.trailing, 16).hidden()
        }
        .padding(.vertical, 8)
        .background(AppTheme.bgSolid)
        .headerDivider()
    }

    // MARK: - Tab Button (Action Blue accent)

    private func tabButton(idx: Int, item: (title: String, icon: String)) -> some View {
        Button(action: {
            withAnimation(AppTheme.Motion.fluid.gated) { selectedTab = idx }
        }) {
            HStack(spacing: 4) {
                Image(systemName: item.icon).font(.system(size: 10))
                Text(item.title).font(.system(size: 11, weight: selectedTab == idx ? .semibold : .regular))
            }
            .foregroundColor(selectedTab == idx ? .white : AppTheme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Capsule())
            .background(
                ZStack {
                    if selectedTab == idx {
                        Capsule()
                            .fill(AppTheme.accentAction)
                            .matchedGeometryEffect(id: "tabBg", in: tabNamespace)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

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
        .transition(.opacity)
        .id(selectedTab)
        .animation(AppTheme.Motion.slow.gated, value: selectedTab)
        .transaction { t in if !AnimationGate.isEnabled { t.disablesAnimations = true; t.animation = nil } }
    }

    // MARK: - Translate Settings

    private var translateSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(title: "词典查词默认模型", icon: "character.book.closed.fill") {
                    Text("查单词时优先使用的模型，留空则跟随当前选择").font(.caption).foregroundColor(AppTheme.textSecondary)
                    if state.enabledProviders.isEmpty {
                        Text("暂无可用模型").font(.caption).foregroundColor(AppTheme.error)
                    } else {
                        Picker("", selection: Binding(get: { state.dictProviderID }, set: { id in state.dictProviderID = id; ProviderStorageManager.saveDictProviderID(id) })) {
                            Text("跟随当前选择").tag(nil as UUID?)
                            ForEach(state.enabledProviders) { p in Text("\(p.name) · \(p.modelName)").tag(p.id as UUID?) }
                        }.pickerStyle(.menu).frame(maxWidth: 280).liquidMenuStyle()
                    }
                }
                settingsCard(title: "语言方向", icon: "arrow.left.arrow.right") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("源语言").font(.caption2).foregroundColor(AppTheme.textSecondary)
                            Picker("", selection: $state.sourceLang) { ForEach(TranslationLanguage.allCases) { l in Text(l.rawValue).tag(l) } }
                                .pickerStyle(.menu).frame(width: 110).liquidMenuStyle()
                        }
                        Image(systemName: "arrow.right").foregroundColor(.secondary).padding(.top, 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("目标语言").font(.caption).foregroundColor(AppTheme.textSecondary)
                            Picker("", selection: $state.targetLang) { ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Text(l.rawValue).tag(l) } }
                                .pickerStyle(.menu).frame(width: 110).liquidMenuStyle()
                        }
                    }
                }
                settingsCard(title: "失败自动降级", icon: "arrow.triangle.branch") {
                    toggleRow(title: "启用后当前 API 失败时按列表顺序尝试下一个", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "fallback_on_failure") }, set: { UserDefaults.standard.set($0, forKey: "fallback_on_failure") }))
                }
                settingsCard(title: "上下文感知翻译", icon: "text.viewfinder") {
                    toggleRow(title: "开启后自动截取划词前后文本作为大模型语境参考，可提升翻译准确性", isOn: $isContextAware)
                    if isContextAware {
                        contextIntensitySlider
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                settingsCard(title: "翻译缓存", icon: "archivebox") {
                    VStack(alignment: .leading, spacing: 10) {
                        toggleRow(title: "启用本地翻译缓存，相同文本与语境下直接复用结果，避免重复 API 调用", isOn: $cacheEnabled)
                        Text("关闭后每次翻译都会重新请求 API，适合调试 Prompt 或测试不同模型效果。")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textCaptionGray)
                    }
                }
                settingsCard(title: "自定义翻译提示词", icon: "text.append") {
                    HStack {
                        Text("支持 {sourceLang} / {targetLang} 变量").font(.caption).foregroundColor(AppTheme.textSecondary); Spacer()
                        Toggle("", isOn: $customPromptEnabled).elegantToggle()
                    }
                    TextEditor(text: Binding(get: { customPromptEnabled ? (customPromptText.isEmpty ? defaultPrompt() : customPromptText) : defaultPrompt() }, set: { if customPromptEnabled { customPromptText = $0 } }))
                        .font(.system(size: 12, design: .monospaced)).frame(minHeight: 80, maxHeight: 130).scrollContentBackground(.hidden)
                        .padding(4).background(Color.primary.opacity(0.05)).cornerRadius(6)
                        .opacity(customPromptEnabled ? 1.0 : 0.4).disabled(!customPromptEnabled)
                    Button(action: resetCustomPrompt) { Label("恢复默认", systemImage: "arrow.counterclockwise").font(.caption) }.buttonStyle(.borderless).foregroundColor(.secondary)
                }
            }.padding()
        }
    }

    // MARK: - History

    private var isHistoryEnabled: Binding<Bool> {
        Binding(
            get: { !historyDisabled },
            set: { historyDisabled = !$0 }
        )
    }

    // ── Filtered history (search + time-sorted) ──
    private var filteredHistoryItems: [HistoryEntry] {
        let items = state.translationHistory
        if historySearchText.isEmpty {
            return items.sorted(by: { $0.timestamp > $1.timestamp })
        }
        return items.filter { item in
            if item.isDictionaryMode {
                // Dictionary: search ONLY visible text (definitions, examples, phonetic)
                // — never JSON keys, never the original word
                let visibleText = dictionaryVisibleText(from: item.output)
                return visibleText.localizedCaseInsensitiveContains(historySearchText)
            } else {
                // Translation: search input + output text
                return item.input.localizedCaseInsensitiveContains(historySearchText) ||
                       item.output.localizedCaseInsensitiveContains(historySearchText)
            }
        }.sorted(by: { $0.timestamp > $1.timestamp })
    }

    /// Extracts only human-visible text from a dictionary JSON blob:
    /// definitions meanings, example sentences, and phonetic notation.
    /// JSON structural keys (`is_word`, `definitions`, `examples`, `pos`, etc.)
    /// and metadata are excluded so search never matches them.
    private func dictionaryVisibleText(from jsonString: String) -> String {
        guard let entry = DictionaryEntry.parse(from: jsonString, word: "") else {
            // If parse fails, fall back to the raw string (user still sees it)
            return jsonString
        }
        var parts: [String] = []
        if !entry.phonetic.isEmpty { parts.append(entry.phonetic) }
        for def in entry.definitions {
            parts.append(def.meaning)
        }
        for ex in entry.examples {
            parts.append(ex.en)
            parts.append(ex.zh)
        }
        return parts.joined(separator: " ")
    }

    private var historySettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ── Compact config card ──
                HStack(spacing: AppTheme.spaceMD) {
                    // 最大条数
                    HStack(spacing: 6) {
                        Text("最大条数")
                            .font(.system(size: 13))
                            .foregroundColor(AppTheme.textPrimary)
                        TextField("", text: $maxHistoryText)
                            .frame(width: 48)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit {
                                if let v = Int(maxHistoryText), v > 0, v <= 500 {
                                    maxHistoryCount = v
                                } else {
                                    maxHistoryText = "\(maxHistoryCount)"
                                }
                            }
                            .onAppear { maxHistoryText = "\(maxHistoryCount)" }
                    }

                    Spacer()

                    // 保存翻译历史 — 正向逻辑 Toggle
                    Toggle(isOn: isHistoryEnabled) {
                        Text("保存翻译历史")
                            .font(.system(size: 13))
                    }
                    .elegantToggle()
                    .animation(AppTheme.Motion.snip.gated, value: historyDisabled)

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 4)

                    // 清除全部
                    if !state.translationHistory.isEmpty {
                        Button(action: { state.clearHistory() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                Text("清除全部")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppTheme.spaceMD)
                .padding(.vertical, 10)
                .background(AppTheme.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous)
                        .stroke(AppTheme.cardBorder, lineWidth: 0.5)
                )

                // ── Search bar ──
                if !historyDisabled && !state.translationHistory.isEmpty {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("搜索原文、译文或词典记录...", text: $historySearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                        if !historySearchText.isEmpty {
                            Button(action: { historySearchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .padding(.horizontal, AppTheme.spaceMD)
                }

                // ── History list ──
                if historyDisabled {
                    Text("历史记录已关闭").font(.caption).foregroundColor(AppTheme.textSecondary).frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if filteredHistoryItems.isEmpty && !state.translationHistory.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title).foregroundColor(.secondary)
                        Text("无匹配记录").font(.subheadline).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if state.translationHistory.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock").font(.title).foregroundColor(.secondary)
                        Text("暂无翻译记录").font(.subheadline).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    ForEach(filteredHistoryItems) { item in
                        historyCard(item)
                    }
                }
            }.padding()
        }
        .onAppear { state.loadFullHistory() }
        .onDisappear {
            state.trimHistory()
            expandedHistoryItemId = nil
        }
    }

    // MARK: - History Card (Expandable)

    @ViewBuilder
    private func historyCard(_ item: HistoryEntry) -> some View {
        let isExpanded = expandedHistoryItemId == item.id

        VStack(alignment: .leading, spacing: 8) {
            // ── Card header (always visible) ──
            HStack {
                Text(item.providerName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppTheme.accentAction)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(AppTheme.accentAction.opacity(0.1)).cornerRadius(3)
                if item.isContextAwareEnabled {
                    Text("Context").font(.system(size: 8, weight: .bold))
                        .foregroundColor(AppTheme.textCaptionGray)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(AppTheme.accentAction.opacity(0.08))
                        .cornerRadius(2)
                }
                if item.isDictionaryMode {
                    Text("词典").font(.system(size: 8, weight: .bold))
                        .foregroundColor(.purple.opacity(0.7))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Color.purple.opacity(0.08))
                        .cornerRadius(2)
                }
                Spacer()
                Text(relativeTimeString(from: item.timestamp))
                    .font(.caption2).foregroundColor(AppTheme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }

            Text(item.input)
                .font(.caption).lineLimit(isExpanded ? nil : 1)
                .foregroundColor(AppTheme.textPrimary)

            if !isExpanded {
                Text(item.output)
                    .font(.caption).lineLimit(1)
                    .foregroundColor(AppTheme.textSecondary)
            }

            // ── Expanded content ──
            if isExpanded {
                Divider().padding(.vertical, 2)

                if item.isDictionaryMode {
                    if let entry = DictionaryEntry.parse(from: item.output, word: item.input) {
                        compactDictionaryBlock(entry)
                    } else {
                        Text(item.output)
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("译文：")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Text(item.output)
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textPrimary)
                            .textSelection(.enabled)
                    }
                }

                // ── Restore button ──
                Button(action: { restoreHistory(item) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                        Text("恢复到翻译面板").font(.system(size: 11))
                    }
                    .foregroundColor(AppTheme.accentAction)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(AppTheme.cardSurface)
        .cornerRadius(AppTheme.radiusSM)
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if isExpanded {
                    expandedHistoryItemId = nil
                } else {
                    expandedHistoryItemId = item.id
                }
            }
        }
    }

    // MARK: - Compact Dictionary Block (for history cards)

    @ViewBuilder
    private func compactDictionaryBlock(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Word header — matches FloatingTranslationView style
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.accentAction)
                Text(entry.word.isEmpty ? "—" : entry.word)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                if !entry.phonetic.isEmpty {
                    Text(entry.phonetic)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AppTheme.textSecondary)
                }
            }

            // All definitions
            ForEach(entry.definitions) { def in
                HStack(alignment: .top, spacing: 6) {
                    Text(def.pos).font(.caption2).fontWeight(.bold).foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor))
                    Text(def.meaning).font(.system(size: 12)).foregroundColor(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !entry.examples.isEmpty {
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.examples) { ex in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ex.en).font(.system(size: 11)).italic().foregroundColor(AppTheme.textPrimary)
                            Text(ex.zh).font(.system(size: 10)).foregroundColor(AppTheme.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - About

    private var aboutSettingsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let iconPath = Bundle.main.path(forResource: "icon", ofType: "icns"), let nsImage = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: nsImage).resizable().frame(width: 72, height: 72).cornerRadius(16).shadow(radius: 4)
                } else { Image(systemName: "character.bubble.fill").font(.system(size: 48)).foregroundColor(AppTheme.accentAction) }
                Text("OmniTrans").font(.title2).bold()
                Text("v\(kAppVersion)").font(.subheadline).foregroundColor(AppTheme.textSecondary)
                Text("菜单栏翻译 · 划词 · OCR · 词典 · TTS · 多引擎").font(.caption).foregroundColor(AppTheme.textSecondary)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    FeatureRow(icon: "text.bubble", text: "划词翻译 — \(HotkeyManager.hotkeyLabel()) 选中即译")
                    FeatureRow(icon: "rectangle.dashed", text: "OCR 框选 — \(HotkeyManager.ocrHotkeyLabel()) 框选屏幕取字")
                    FeatureRow(icon: "arrow.triangle.swap", text: "原位替换 — \(HotkeyManager.replaceHotkeyLabel()) 直接粘贴译文")
                    FeatureRow(icon: "character.book.closed", text: "智能词典 — 自动检测单词，结构化释义 + 音标 + 例句")
                    FeatureRow(icon: "speaker.wave.2", text: "TTS 朗读 — 翻译结果与词典词汇一键朗读")
                    FeatureRow(icon: "globe", text: "9 个引擎 — OpenAI · Claude · Gemini · 通义 · DeepSeek · 火山 · Google · Bing · 阿里")
                    FeatureRow(icon: "arrow.triangle.branch", text: "智能降级 — AI → MT → 原生引擎逐级回退")
                    FeatureRow(icon: "cpu", text: "原生引擎 — macOS 内置词典 + Translation API")
                    FeatureRow(icon: "text.quote", text: "场景预设 — 翻译/润色/口语/代码/文案 5 种 Prompt")
                    FeatureRow(icon: "rectangle.expand.vertical", text: "动态窗口 — 小/默认/大/动态 四种尺寸")
                    FeatureRow(icon: "rectangle.on.rectangle", text: "剪贴板监听 — 后台 0% CPU · NSWorkspace 通知驱动")
                    FeatureRow(icon: "arrow.up.arrow.down", text: "拖动排序 — API 配置卡片自由重排，持久化保存")
                    FeatureRow(icon: "lock.shield", text: "隐私 — AES-256-GCM 文件加密，密钥绑定 IOPlatformUUID")
                }
                Divider()
                Text("OmniTrans · SwiftUI · 零第三方依赖 · 2026").font(.caption2).foregroundColor(AppTheme.textSecondary)
                Divider()
                Button(action: { UserDefaults.standard.set(false, forKey: "has_completed_onboarding"); let a = NSAlert(); a.messageText = "已重置引导页"; a.informativeText = "下次启动时将重新显示首次使用引导。"; a.alertStyle = .informational; a.addButton(withTitle: "好的"); a.runModal() }) {
                    Label("重置首次使用引导", systemImage: "arrow.counterclockwise").font(.caption)
                }.buttonStyle(.borderless).foregroundColor(.secondary)
            }.padding()
        }
    }

    // MARK: - Context Intensity Slider

    private var contextIntensitySlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(value: Binding(
                get: { Double(contextIntensity) },
                set: { contextIntensity = Int($0.rounded()) }
            ), in: 0...4, step: 1)
                .tint(AppTheme.accentAction)

            HStack(spacing: 0) {
                ForEach(0..<5) { tier in
                    let chars = [100, 200, 300, 400, 500][tier]
                    Text("\(chars)")
                        .font(.system(size: 11))
                        .foregroundColor(contextIntensity == tier ? AppTheme.accentAction : AppTheme.textCaptionGray)
                        .frame(maxWidth: .infinity, alignment: tier == 0 ? .leading : tier == 4 ? .trailing : .center)
                }
            }

            Text("提示：上下文感知强度开得越高，单次请求消耗的 Token 越大，但翻译的术语准确性与连贯性越高。")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textCaptionGray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(AppTheme.Motion.snip.gated, value: contextIntensity)
    }

    // MARK: - Relative Time (no per-second timer — static string)

    /// Returns a static relative-time string computed once at render time.
    /// < 60 s → "刚刚", otherwise minute-based ("5 分钟前", "1 小时前", etc.).
    /// This eliminates per-second `Timer`-driven re-renders in history lists.
    private func relativeTimeString(from date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "刚刚" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let days = hours / 24
        return "\(days) 天前"
    }

    // MARK: - Helpers

    private func settingsCard<C: View>(title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            Label(title, systemImage: icon).font(.subheadline).bold().foregroundColor(AppTheme.textPrimary)
            content()
        }.nativeCardStyle()
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundColor(AppTheme.textCaptionGray).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Toggle("", isOn: isOn).elegantToggle()
        }
    }

    private func defaultPrompt() -> String {
        "You are a professional translator. Translate the following text to {targetLang} accurately and concisely. Preserve the original meaning, tone, and formatting. Output only the translation without any explanations, notes, or markdown fences."
    }
    private func resetCustomPrompt() { customPromptText = defaultPrompt() }
    private func restoreHistory(_ item: HistoryEntry) {
        state.inputText = item.input; state.translatedText = item.output
        state.sourceLang = item.sourceLang; state.targetLang = item.targetLang
        state.errorMessage = nil
        if item.isDictionaryMode {
            state.isDictionaryMode = true
            // ── Parse stored JSON + hard-lock cache for menu bar resilience ──
            if let entry = DictionaryEntry.parse(from: item.output, word: item.input) {
                state.dictionaryEntry = entry
                state.session.lastValidDictionaryJson = item.output
            } else {
                state.dictionaryEntry = nil
                state.isDictionaryMode = false
            }
        } else {
            state.isDictionaryMode = false
            state.dictionaryEntry = nil
        }
        if let p = state.providers.first(where: { $0.name == item.providerName }) { state.selectedProviderID = p.id; ProviderStorageManager.saveSelectedProviderID(p.id) }
        isPresented = false
    }
}

private struct FeatureRow: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 18).foregroundColor(AppTheme.accentAction).font(.caption)
            Text(text).font(.caption).foregroundColor(AppTheme.textPrimary)
        }
    }
}
