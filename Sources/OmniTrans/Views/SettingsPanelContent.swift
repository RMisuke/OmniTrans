import SwiftUI
import Carbon

// MARK: - Settings Panel Content (v1.0 — Full Animation Integration)

/// Settings panel with comprehensive, multi-layered animations for every interaction.
///
/// ## Animation Coverage
/// - **Tab bar**: animated selection indicator + content crossfade
/// - **Cards**: hover scale + staggered entrance
/// - **Toggles**: associated content reveal/collapse with spring
/// - **Sliders**: value label pulse + description text crossfade
/// - **Buttons**: pressable scale feedback + reset emphasis glow
/// - **Hotkey recording**: breathing pulse indicator + completion bounce
/// - **Advanced options**: expand/collapse with smooth spring
/// - **About page**: staggered feature list + icon entrance
///
/// All animations are configured via `AppTheme.Motion` tokens,
/// gated through `AnimationGate`, and respect `reduce motion`.
struct SettingsPanelContent: View {
    @ObservedObject var state: AppState
    @State private var selectedTab = 0

    @State private var wipeState: WipeStage = .idle
    @State private var wipeCountdown = 10
    @State private var wipeTimer: Timer?

    enum WipeStage { case idle, counting, ready }

    @AppStorage("panel_size") private var panelSize = "default"
    @AppStorage("dismiss_mode") private var dismissMode = "clickOutside"
    @AppStorage("clipboard_monitor") private var clipboardMonitor = false
    @AppStorage("history_disabled") private var historyDisabled = false
    @AppStorage("max_history_count") private var maxHistoryCount = 100
    @AppStorage("cache_enabled") private var cacheEnabled = true
    @AppStorage("is_context_aware") private var isContextAware = true
    @AppStorage("context_intensity") private var contextIntensity = 2
    @AppStorage("custom_prompt_enabled") private var customPromptEnabled = false
    @AppStorage("custom_prompt_text") private var customPromptText = ""
    @AppStorage("dict_cache_enabled") private var dictCacheEnabled = true
    @AppStorage("translation_temperature") private var translationTemp: Double = 0.3
    @AppStorage("translation_maxTokens") private var translationMaxTokens: Int = 1024
    @State private var maxHistoryText = "100"
    @State private var showAdvanced = false
    @State private var recordingKey: String? = nil
    @State private var refreshID = UUID()

    // ── Animation State ──

    /// Triggers staggered card entrance on tab switch.
    @State private var cardsVisible = false
    /// Tracks which cards are hovered for per-card scale feedback.
    @State private var hoveredCardIndex: Int? = nil
    /// Pulse trigger for slider value labels (context intensity).
    @State private var sliderPulseTrigger = UUID()
    /// Pulse trigger for temperature slider — separate from value so it only
    /// fires on discrete 0.05-step changes, not on every @AppStorage sync.
    @State private var tempPulseTrigger = UUID()

    private let tabItems: [(title: String, icon: String)] = [
        ("翻译", "arrow.triangle.2.circlepath"), ("API", "server.rack"),
        ("通用", "gearshape"), ("关于", "info.circle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Layer 1: Tab 栏区域。
            //     NSVisualEffectView（Layer 0）已在 AppKit 层覆盖全窗，
            //     此处不再需要 SwiftUI 材质。仅保留 Tab 栏自身结构。
            //     显式 .padding(.top, 28) 作为安全区保护垫：
            //     在 safeArea 归零的场景（全屏/刘海屏）下，
            //     强制保留至少 28pt 防止 Tab 栏暴冲到标题栏。
            VStack(spacing: 0) {
                animatedTabBar
                    .frame(height: 48)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
            }
            // ── 柔和下投影替代硬分割线：
            //     Y 偏移 4pt、模糊 8pt、不透明度 0.15，
            //     在 Tab 栏与滚动内容之间形成自然深度过渡。
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            .padding(.top, 28)

            // ── 内容区：带顶部渐变遮罩的 ScrollView。
            //     线性渐变 Alpha 遮罩在顶部 8pt 区间从透明过渡到不透明，
            //     实现滚动内容进入 Tab 栏底部区域时的平滑羽化淡隐，
            //     替代 v1.0 的硬材质 zIndex 遮挡方案。
            ZStack {
                contentArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 1)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 8)
                    Color.white
                }
            )
        }
        .frame(minWidth: 460, minHeight: 540)
        // ── 圆角由 AppKit 层的 NSVisualEffectView (Layer 0) 通过
        //     layer.cornerRadius + masksToBounds 统一控制。
        //     此处不设置 clipShape —— 避免 SwiftUI 裁剪坐标系与
        //     hostingView 的 y=0 对齐冲突，导致顶部毛玻璃被误切。
        .accentColor(Color(nsColor: .controlAccentColor))
        // ── 显式 tint 确保分段选择器 (Picker .segmented) 在窗口
        //     激活时显示系统强调蓝色，而非 inactive 灰色。
        .tint(.accentColor)
        .onAppear {
            loadSettingsFromProvider()
            // Trigger card entrance on next runloop so initial state applies first.
            DispatchQueue.main.async {
                withAnimation(AppTheme.Motion.panelOpen.resolveGated()) {
                    cardsVisible = true
                }
            }
        }
        .onChange(of: selectedTab) { _, _ in
            // Reset stagger for re-entrance on tab switch.
            // Also collapse advanced options to prevent their expand transition
            // from overlapping the card entrance animation.
            showAdvanced = false
            cardsVisible = false
            DispatchQueue.main.async {
                withAnimation(AppTheme.Motion.panelOpen.resolveGated()) {
                    cardsVisible = true
                }
            }
        }
        .onChange(of: state.selectedProviderID) { _, _ in
            loadSettingsFromProvider()
        }
        .onChange(of: translationTemp) { _, newValue in
            syncTemperatureToProvider(newValue)
        }
        .onChange(of: translationMaxTokens) { _, newValue in
            syncMaxTokensToProvider(newValue)
        }
        .onChange(of: customPromptEnabled) { _, enabled in
            if enabled, customPromptText.isEmpty {
                customPromptText = defaultPrompt
            }
            syncCustomPromptToJSON()
        }
        .onChange(of: customPromptText) { _, _ in
            syncCustomPromptToJSON()
        }
    }

    // ── Settings Persistence ──

    /// Load temperature/maxTokens from the current (non-built-in) provider into @AppStorage,
    /// ensuring the Settings panel shows what the translation engine actually uses.
    private func loadSettingsFromProvider() {
        guard let provider = state.selectedProvider, !provider.isBuiltIn else { return }
        translationTemp = provider.temperature
        translationMaxTokens = provider.maxTokens
    }

    /// Push temperature change to the selected provider so TranslationActor uses it.
    private func syncTemperatureToProvider(_ newValue: Double) {
        guard let provider = state.selectedProvider, !provider.isBuiltIn else { return }
        var updated = provider
        updated.temperature = newValue
        state.updateProvider(updated)
    }

    /// Push maxTokens change to the selected provider.
    private func syncMaxTokensToProvider(_ newValue: Int) {
        guard let provider = state.selectedProvider, !provider.isBuiltIn else { return }
        var updated = provider
        updated.maxTokens = newValue
        state.updateProvider(updated)
    }

    /// Sync the two separate @AppStorage keys into the single JSON-encoded
    /// "custom_prompt" key that TranslationActor.buildHint() reads.
    private func syncCustomPromptToJSON() {
        let cp = CustomPrompt(enabled: customPromptEnabled, text: customPromptText)
        if let data = try? JSONEncoder().encode(cp) {
            UserDefaults.standard.set(data, forKey: "custom_prompt")
        }
    }

    // MARK: - Tab Bar

    private var animatedTabBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(tabItems.enumerated()), id: \.offset) { idx, item in
                tabButton(idx: idx, item: item)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 2).padding(.top, 2)
    }

    private func tabButton(idx: Int, item: (title: String, icon: String)) -> some View {
        let isSelected = selectedTab == idx
        return Button {
            withAnimation(AppTheme.Motion.tabSelect.resolveGated()) { selectedTab = idx }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .scaleEffect(isSelected ? 1.1 : 1.0)
                Text(item.title)
                    .font(.system(size: 12, weight: isSelected ? .bold : .semibold))
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(
                isSelected
                    ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                    : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .scaleEffect(isSelected ? 1.0 : 0.97)
        }
        .buttonStyle(PressableButtonStyle())
        // ── 扩大点击热区：额外 4pt padding + Rectangle 命中区域
        //     确保 Tab 边缘点击也能触发切换，避免事件被吞。
        .padding(4)
        .contentShape(Rectangle())
        .animation(AppTheme.Motion.tabSelect.resolveGated(), value: isSelected)
    }

    // MARK: - Content Area

    @ViewBuilder private var contentArea: some View {
        ScrollView {
            VStack {
                switch selectedTab {
                case 0: translationTab
                case 1: apiTab
                case 2: generalTab
                case 3: aboutTab
                default: EmptyView()
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        // ── Unlock edge rendering so shadows / overlays aren't clipped,
        //     but inset the scroll indicator so it stays within the 20pt
        //     corner radius instead of hitting the hard right edge.
        .scrollClipDisabled()
        .padding(.trailing, 4)
    }

    // MARK: - Translation Tab

    private var translationTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            animatedCard(icon: "globe", title: "翻译语言", index: 0) {
                HStack(spacing: 8) {
                    Text("源语言").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    Picker("", selection: $state.sourceLang) {
                        ForEach(TranslationLanguage.allCases) { l in Text(l.rawValue).tag(l) }
                    }.pickerStyle(.menu).frame(width: 120)
                    Spacer()
                    Image(systemName: "arrow.forward")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.accentColor)
                        .rotationEffect(.degrees(state.sourceLang != .auto ? 0 : -10))
                        .animation(AppTheme.Motion.snip.resolveGated(), value: state.sourceLang)
                    Spacer()
                    Text("目标语言").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    Picker("", selection: $state.targetLang) {
                        ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Text(l.rawValue).tag(l) }
                    }.pickerStyle(.menu).frame(width: 120)
                }
            }

            animatedCard(icon: "server.rack", title: "翻译服务", index: 1) {
                VStack(spacing: 10) {
                    providerRow(icon: "cpu", label: "翻译默认 API",
                                selection: Binding(get: { state.selectedProviderID }, set: { id in
                                    state.selectedProviderID = id; ProviderStorageManager.saveSelectedProviderID(id)
                                }))
                    Divider()
                    providerRow(icon: "character.book.closed", label: "词典默认 API",
                                selection: Binding(get: { state.dictProviderID }, set: { id in
                                    state.dictProviderID = id; ProviderStorageManager.saveDictProviderID(id)
                                }),
                                hasAutoOption: true)
                }
            }

            animatedCard(icon: "brain.head.profile", title: "语境感知", index: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用语境感知翻译", isOn: $isContextAware)
                        .toggleStyle(.switch).controlSize(.small)
                    if isContextAware {
                        contextIntensitySection
                            .transition(AppTheme.Motion.toggleReveal.asAsymmetricTransition(removal: AppTheme.Motion.toggleCollapse))
                    }
                }
            }

            animatedCard(icon: "clock.arrow.circlepath", title: "翻译历史", index: 3) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("最大保存条数").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        TextField("", text: $maxHistoryText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onAppear {
                                // Sync text field with the actual stored value on every appear,
                                // so it never shows a stale hardcoded "100".
                                maxHistoryText = String(maxHistoryCount)
                            }
                            .onChange(of: maxHistoryText) { _, v in
                                // Only commit when the text is a valid positive integer;
                                // ignore empty / non-numeric input so we don't clobber the
                                // stored value with the fallback (100) while the user is editing.
                                guard let newValue = Int(v), newValue > 0 else { return }
                                if newValue != maxHistoryCount {
                                    maxHistoryCount = newValue
                                }
                            }
                    }
                    Toggle("禁用历史记录", isOn: $historyDisabled)
                        .toggleStyle(.switch).controlSize(.small)
                }
            }
            .onChange(of: maxHistoryCount) { _, _ in
                state.applyHistoryLimit()
            }

            animatedCard(icon: "cylinder.split.1x2.fill", title: "词典缓存", index: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启用词典本地缓存", isOn: $dictCacheEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    Text("关闭此开关后只会停止从本地缓存中查找数据，不会删除已保存的词典数据。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Advanced Options
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("高级选项", isOn: $showAdvanced)
                        .toggleStyle(.switch).controlSize(.small)
                    Text("请充分了解参数后再操作，以免影响翻译质量")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if showAdvanced {
                    advancedOptions
                        .transition(AppTheme.Motion.expandReveal.asAsymmetricTransition(removal: AppTheme.Motion.expandCollapse, insertionOffset: 8, removalOffset: -8))
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
            .opacity(cardsVisible ? 1 : 0)
            .offset(y: cardsVisible ? 0 : 8)
            .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.2), value: cardsVisible)
        }
    }

    // MARK: - Context Intensity

    private var contextIntensitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("上下文长度").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                Slider(value: Binding(get: { Double(contextIntensity) },
                                      set: { newVal in
                    let rounded = Int(newVal.rounded())
                    if rounded != contextIntensity {
                        contextIntensity = rounded
                        sliderPulseTrigger = UUID()
                    }
                }), in: 0...4, step: 1).controlSize(.small)
                Text(contextSliders[contextIntensity].0)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .modifier(ValuePulseModifier(trigger: sliderPulseTrigger))
            }
            Text(contextSliders[contextIntensity].1)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .id("ctx-desc-\(contextIntensity)")
                .transition(AppTheme.Motion.sliderTextCrossfade.asTransition(offset: 0))
                .animation(AppTheme.Motion.sliderTextCrossfade.resolveGated(), value: contextIntensity)
        }
    }

    // MARK: - Provider Row Helper

    private func providerRow(icon: String, label: String,
                             selection: Binding<UUID?>, hasAutoOption: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(.accentColor).frame(width: 18)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            Picker("", selection: selection) {
                if hasAutoOption {
                    Text("跟随翻译 API").tag(nil as UUID?)
                }
                ForEach(state.enabledProviders) { p in
                    Text("\(p.name) · \(p.modelName)").tag(p.id as UUID?)
                }
            }.pickerStyle(.menu).frame(width: 240)
        }
    }

    private let contextSliders: [(String, String)] = [
        ("最低", "100 字符 — 极省 Token，但上下文理解较弱，适合短单词查询"),
        ("较低", "200 字符 — 轻度上下文，适合短语和简单句子翻译"),
        ("默认", "300 字符 — 推荐平衡点，兼顾准确度与 Token 消耗"),
        ("较高", "400 字符 — 增强上下文，适合段落翻译和代词指代"),
        ("最高", "500 字符 — 最强语境理解，适合专业文献和长难句，Token 消耗最高"),
    ]

    // MARK: - Advanced Options

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            advRow("温度", tip: "控制生成文本的随机性。值越低输出越确定一致（适合代码/术语），值越高回复越多样（适合创意翻译）。范围 0~2，推荐 0.3。") {
                VStack(spacing: 8) {
                    HStack {
                        Slider(value: Binding(get: { translationTemp }, set: { newVal in
                            let snapped = (newVal * 20).rounded() / 20  // snap to 0.05
                            if abs(snapped - translationTemp) > 0.001 {
                                translationTemp = snapped
                                tempPulseTrigger = UUID()
                            }
                        }), in: 0.0...2.0, step: 0.05).controlSize(.small)
                        Text(String(format: "%.2f", translationTemp))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .frame(width: 36)
                            .modifier(ValuePulseModifier(trigger: tempPulseTrigger))
                        resetButton("默认", action: { withAnimation(AppTheme.Motion.resetEmphasis.resolveGated()) { translationTemp = 0.3 } })
                    }
                    HStack(spacing: 6) {
                        temperaturePreset("精确", 0.1)
                        temperaturePreset("均衡", 0.7)
                        temperaturePreset("创意", 1.0)
                    }
                }
            }
            advRow("最大 Token", tip: "限制 AI 单次回复的最大长度。值越小响应越快、费用越低；值越大可处理更长的翻译结果。短文本推荐 1024，长文推荐 4096。") {
                HStack {
                    TextField("", value: $translationMaxTokens, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80).font(.system(size: 11))
                        .onChange(of: translationMaxTokens) { _, newValue in
                            if newValue < 1 { translationMaxTokens = 1 }
                        }
                    Stepper("", value: $translationMaxTokens, in: 1...16384, step: 256).labelsHidden()
                    resetButton("默认", action: { withAnimation(AppTheme.Motion.resetEmphasis.resolveGated()) { translationMaxTokens = 1024 } })
                }
            }
            advRow("翻译缓存", tip: "关闭翻译缓存会增加重复划词翻译的 API 消耗和响应时间。默认建议保持开启。") {
                Toggle("启用翻译缓存", isOn: $cacheEnabled)
                    .toggleStyle(.switch).controlSize(.small)
            }
            advRow("自定义提示词", tip: "自定义发送给 AI 的系统指令。支持 {sourceLang} 和 {targetLang} 占位符，翻译时自动替换。") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启用自定义提示词", isOn: $customPromptEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    TextEditor(text: Binding(
                        get: { customPromptText.isEmpty ? defaultPrompt : customPromptText },
                        set: { if customPromptEnabled { customPromptText = $0 } }
                    ))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(minHeight: 50, maxHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .opacity(customPromptEnabled ? 1 : 0.4)
                    .disabled(!customPromptEnabled)
                    .animation(AppTheme.Motion.toggleReveal.resolveGated(), value: customPromptEnabled)
                    HStack {
                        Spacer()
                        resetButton("恢复默认", action: {
                            withAnimation(AppTheme.Motion.resetEmphasis.resolveGated()) { customPromptText = defaultPrompt }
                        })
                    }
                }
            }
        }
    }

    private func temperaturePreset(_ label: String, _ value: Double) -> some View {
        let isActive = abs(translationTemp - value) < 0.05
        return Button {
            withAnimation(AppTheme.Motion.snip.resolveGated()) { translationTemp = value }
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.quaternary))
                .foregroundColor(isActive ? .accentColor : .secondary)
                .clipShape(Capsule())
                .scaleEffect(isActive ? 1.05 : 1.0)
        }
        .buttonStyle(PressableButtonStyle())
        .animation(AppTheme.Motion.snip.resolveGated(), value: isActive)
    }

    private func resetButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func advRow(_ label: String, tip: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .help(tip)
                Spacer()
            }
            content()
        }
    }

    private var defaultPrompt: String {
        "You are a professional translator. Translate the following text to {targetLang} accurately and concisely."
    }

    // MARK: - Animated Card

    /// Card with staggered entrance + hover scale feedback.
    private func animatedCard<Content: View>(icon: String, title: String, index: Int,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }.padding(.bottom, 8)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(hoveredCardIndex == index ? 0.22 : 0.16),
                        radius: hoveredCardIndex == index ? 14 : 10,
                        x: 0, y: hoveredCardIndex == index ? 5 : 4)
                .scaleEffect(hoveredCardIndex == index ? 1.015 : 1.0)
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .opacity(cardsVisible ? 1 : 0)
        .offset(y: cardsVisible ? 0 : 8)
        .animation(
            AppTheme.Motion.panelOpen.resolveGated()?.delay(Double(index) * 0.06),
            value: cardsVisible
        )
        .onHover { hovering in
            withAnimation(AppTheme.Motion.buttonHover.resolveGated()) {
                hoveredCardIndex = hovering ? index : nil
            }
        }
    }

    // MARK: - API Tab

    private var apiTab: some View {
        ProviderSettingsView(state: state)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            animatedCard(icon: "paintpalette", title: "外观", index: 0) {
                HStack {
                    Text("主题模式").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { ThemeEngine.shared.mode },
                        set: { ThemeEngine.shared.setMode($0) }
                    )) {
                        ForEach(ThemeMode.allCases, id: \.self) { m in Text(m.displayName).tag(m) }
                    }.pickerStyle(.segmented).padding(.horizontal, 4).padding(.vertical, 2)
                }
            }
            animatedCard(icon: "macwindow", title: "窗口", index: 1) {
                VStack(spacing: 10) {
                    HStack {
                        Text("关闭方式").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $dismissMode) {
                            Text("点击框外").tag("clickOutside"); Text("手动关闭").tag("manual")
                        }.pickerStyle(.segmented).fixedSize().padding(.horizontal, 4).padding(.vertical, 2)
                    }
                    HStack {
                        Text("悬浮窗尺寸").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $panelSize) {
                            Text("小").tag("small"); Text("默认").tag("default")
                            Text("大").tag("large"); Text("动态").tag("dynamic")
                        }.pickerStyle(.segmented).fixedSize().padding(.horizontal, 4).padding(.vertical, 2)
                    }
                }
            }
            animatedCard(icon: "clipboard", title: "剪贴板", index: 2) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启用剪贴板监听", isOn: $clipboardMonitor)
                        .toggleStyle(.switch).controlSize(.small)
                        .onChange(of: clipboardMonitor) { _, on in
                            if on { ClipboardMonitor.shared.start() } else { ClipboardMonitor.shared.stop() }
                        }
                    Text("⚠️ 剪贴板监听仅在关闭全局快捷键时生效，否则快捷键会拦截复制操作。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            animatedCard(icon: "command", title: "快捷键", index: 3) {
                VStack(spacing: 12) {
                    animatedHotkeyRow("划词翻译", "hotkey") { c, m in
                        HotkeyManager.shared.reregister(carbonKey: c, carbonMods: m)
                    }
                    animatedHotkeyRow("OCR 翻译", "ocr_hotkey") { c, m in
                        HotkeyManager.shared.reregisterOCR(carbonKey: c, carbonMods: m)
                    }
                    animatedHotkeyRow("原位替换", "replace") { c, m in
                        HotkeyManager.shared.reregisterReplace(carbonKey: c, carbonMods: m)
                    }
                }
            }.id(refreshID)
            animatedCard(icon: "externaldrive.fill", title: "个人词典数据管理", index: 4) {
                VStack(spacing: 10) {
                    Button { exportDictionaryCSV() } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                            Text("导出个人词典 (CSV)").font(.system(size: 12))
                            Spacer()
                        }
                    }.buttonStyle(.borderless)

                    Divider()

                    Button { importDictionaryCSV() } label: {
                        HStack {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 12))
                            Text("导入词典数据 (CSV)").font(.system(size: 12))
                            Spacer()
                        }
                    }.buttonStyle(.borderless)

                    Divider()

                    Button { handleWipeTap() } label: {
                        Text(wipeButtonLabel).font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(wipeState == .ready ? .red : .secondary)
                    .disabled(wipeState == .counting)
                    .frame(width: 200)
                    if wipeState == .counting {
                        Text("此行为会彻底删除所有的个人词典缓存数据且不可恢复，请谨慎操作！")
                            .font(.system(size: 10)).foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var wipeButtonLabel: String {
        switch wipeState {
        case .idle:   return "清除全部个人词典数据"
        case .counting: return "确认删除 (\(wipeCountdown)s)"
        case .ready:  return "确认删除"
        }
    }

    private func handleWipeTap() {
        switch wipeState {
        case .idle:
            wipeState = .counting; wipeCountdown = 10
            wipeTimer?.invalidate()
            wipeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    self.wipeCountdown -= 1
                    if self.wipeCountdown <= 0 {
                        self.wipeTimer?.invalidate()
                        self.wipeTimer = nil
                        self.wipeState = .ready
                    }
                }
            }
        case .ready:
            Task { await LocalDictionaryRepository.shared.deleteAll() }
            wipeState = .idle; wipeTimer?.invalidate(); wipeTimer = nil
        case .counting: break
        }
    }

    private func importDictionaryCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let alert = NSAlert()
            alert.messageText = "导入冲突处理"
            alert.informativeText = "如果遇到本地已经缓存的相同词汇，是否用新导入的数据覆盖现有内容？"
            alert.addButton(withTitle: "覆盖"); alert.addButton(withTitle: "跳过")
            alert.alertStyle = .warning
            let overwrite = alert.runModal() == .alertFirstButtonReturn
            Task { await self.performCSVImport(url: url, overwrite: overwrite) }
        }
    }

    private func performCSVImport(url: URL, overwrite: Bool) async {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").dropFirst()
        await LocalDictionaryRepository.shared.batchImport(lines: Array(lines), overwrite: overwrite)
    }

    private func exportDictionaryCSV() {
        let savePanel = NSSavePanel()
        savePanel.title = "导出词典数据"
        savePanel.nameFieldStringValue = "omnitrans_dictionary_\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).csv"
        savePanel.allowedContentTypes = [.commaSeparatedText]

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            Task { await self.writeCSV(to: url) }
        }
    }

    private func writeCSV(to url: URL) async {
        let rows = await LocalDictionaryRepository.shared.fetchAllForExport()
        var csv = "query_word,target_lang,model_name,json_data,updated_at\n"
        for row in rows {
            let escaped = row.jsonData.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(row.word)\",\"\(row.targetLang)\",\"\(row.modelName)\",\"\(escaped)\",\"\(row.timestamp)\"\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[CSV Export] ❌ Write failed: \(error)")
        }
    }

    // MARK: - Animated Hotkey Row

    private func animatedHotkeyRow(_ label: String, _ key: String,
                                    onSet: @escaping (Int, Int) -> Void) -> some View {
        let carbonKey = UserDefaults.standard.integer(forKey: "\(key)_carbonKey")
        let carbonMods = UserDefaults.standard.integer(forKey: "\(key)_carbonMods")
        let display = HotkeyManager.hotkeyLabelFrom(carbonKey: carbonKey, carbonMods: carbonMods)
        let isRecording = recordingKey == key

        return HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Spacer()

            // Key display with recording/completion animation
            if isRecording {
                recordingIndicator
            } else {
                Text(display)
                    .font(.system(size: 11, design: .monospaced))
                    .fontWeight(.medium)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .transition(AppTheme.Motion.recordingComplete.asAsymmetricTransition(removal: AppTheme.Motion.recordingCancel, insertionOffset: 0, removalOffset: 0))
            }

            Button(isRecording ? "取消" : "录制") {
                if isRecording {
                    withAnimation(AppTheme.Motion.recordingCancel.resolveGated()) {
                        stopRecording()
                    }
                } else {
                    withAnimation(AppTheme.Motion.snip.resolveGated()) {
                        startRecording(for: key, onSet: onSet)
                    }
                }
            }
            .font(.system(size: 10))
            .buttonStyle(PressableButtonStyle())
            .foregroundColor(isRecording ? .red : .accentColor)

            resetButton("默认", action: {
                let defKey: Int
                let defMod: Int
                if key == "hotkey" { defKey = Int(kVK_ANSI_D); defMod = Int(optionKey) }
                else if key == "ocr_hotkey" { defKey = Int(kVK_ANSI_F); defMod = Int(optionKey) }
                else { defKey = Int(kVK_ANSI_R); defMod = Int(optionKey) }
                UserDefaults.standard.set(defKey, forKey: "\(key)_carbonKey")
                UserDefaults.standard.set(defMod, forKey: "\(key)_carbonMods")
                onSet(defKey, defMod)
                withAnimation(AppTheme.Motion.resetEmphasis.resolveGated()) {
                    refreshID = UUID()
                }
            })
        }
        .animation(AppTheme.Motion.snip.resolveGated(), value: isRecording)
    }

    /// Breathing recording indicator.
    private var recordingIndicator: some View {
        Text("按下组合键…")
            .font(.system(size: 11))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(recordingKey != nil ? 1.03 : 1.0)
            .animation(
                AppTheme.Motion.recordingPulse.resolve()
                    .repeatForever(autoreverses: true),
                value: recordingKey
            )
    }

    // MARK: - Hotkey Recording

    @State private var keyEventMonitor: Any? = nil

    private func startRecording(for key: String, onSet: @escaping (Int, Int) -> Void) {
        recordingKey = key
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.recordingKey == key else { return event }
            let carbonKey = Int(event.keyCode)
            let mods = HotkeyManager.carbonMods(from: event.modifierFlags)
            UserDefaults.standard.set(carbonKey, forKey: "\(key)_carbonKey")
            UserDefaults.standard.set(Int(mods), forKey: "\(key)_carbonMods")
            onSet(carbonKey, Int(mods))
            DispatchQueue.main.async {
                withAnimation(AppTheme.Motion.recordingComplete.resolveGated()) {
                    self.recordingKey = nil
                    self.refreshID = UUID()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        recordingKey = nil
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon with bouncy entrance
            Image(nsImage: appIcon(size: 72))
                .resizable().frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                .scaleEffect(cardsVisible ? 1.0 : 0.8)
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.iconEntrance.resolveGated()?.delay(0.05), value: cardsVisible)

            Spacer().frame(height: 14)

            Text("OmniTrans")
                .font(.system(size: 22, weight: .bold))
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.1), value: cardsVisible)

            Text("macOS 智能翻译 · 词典 · OCR")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.14), value: cardsVisible)

            Spacer().frame(height: 4)

            Text("版本 \(kAppVersion)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.18), value: cardsVisible)

            Spacer().frame(height: 20)

            // Feature list with stagger
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(features.enumerated()), id: \.offset) { i, featItem in
                    featureRow(icon: featItem.icon, text: featItem.text, index: i)
                }
            }.padding(.horizontal, 28)

            Spacer()

            Button("重新显示引导") {
                UserDefaults.standard.set(false, forKey: "has_completed_onboarding")
                if let w = NSApp.keyWindow { w.close() }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("OmniTransShowOnboarding"),
                        object: nil
                    )
                }
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundColor(.accentColor)
            .font(.system(size: 11))
            .opacity(cardsVisible ? 1 : 0)

            Spacer().frame(height: 8)
        }.frame(maxWidth: .infinity)
    }

    private let features: [(icon: String, text: String)] = [
        ("globe", "多引擎流式翻译 — OpenAI · Claude · Gemini · 本地"),
        ("character.book.closed.fill", "智能词典查词 — 语境感知 · JSON 结构化"),
        ("rectangle.and.text.magnifyingglass", "OCR 屏幕识别 — 框选即译 · Vision 引擎"),
        ("arrow.triangle.swap", "原位替换 — 一键粘贴翻译结果"),
        ("brain.head.profile.fill", "双向上下文感知 — 精准术语与代词指代"),
    ]

    private func featureRow(icon: String, text: String, index: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary)
        }
        .opacity(cardsVisible ? 1 : 0)
        .offset(y: cardsVisible ? 0 : 6)
        .animation(
            AppTheme.Motion.featureStagger.resolveGated()?.delay(Double(index) * 0.05),
            value: cardsVisible
        )
    }

    // MARK: - Helpers

    private func appIcon(size: CGFloat) -> NSImage {
        if let path = Bundle.main.path(forResource: "icon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            let r = NSImage(size: NSSize(width: size, height: size))
            r.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                      from: .zero, operation: .copy, fraction: 1)
            r.unlockFocus()
            return r
        }
        return NSImage(systemSymbolName: "character.bubble.fill",
                       accessibilityDescription: nil)!
    }
}

// MARK: - Value Pulse Modifier

/// Subtle scale pulse on numeric value changes — used for slider value labels.
struct ValuePulseModifier: ViewModifier {
    let trigger: AnyHashable
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.12 : 1.0)
            .animation(AppTheme.Motion.sliderValuePulse.resolveGated(), value: pulsing)
            .onChange(of: trigger) { _, _ in
                pulsing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    pulsing = false
                }
            }
    }
}
