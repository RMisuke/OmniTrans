import SwiftUI
import Carbon
import os

// MARK: - Settings Panel Content (v0.8 — 哑光画布重构)
//
// v0.8 拆分：各 Tab 实现迁移至 Views/Settings/ 扩展文件：
//   - TranslationTab.swift  — 翻译 Tab + 高级选项
//   - GeneralTab.swift      — 通用 Tab + 快捷键录制 + 词典数据管理
//   - AboutTab.swift        — 关于 Tab
//   - AnimatedCard.swift    — 卡片容器 + 共享小组件
//
// 本文件仅保留：状态声明 / body / Tab 栏 / 内容区路由 / 持久化辅助。
//
// v0.8 视觉变更：
//   - 移除 Tab 栏「shadow 当分割线」（滚动内容误裁 Bug 源头）
//   - 移除内容区顶部渐变 mask（同上）
//   - Tab 栏改实底表面，窗口画布由 AppKit 层提供 windowBackground 实底

/// Settings panel with comprehensive, multi-layered animations for every interaction.
///
/// All animations are configured via `AppTheme.Motion` tokens,
/// gated through `AnimationGate`, and respect `reduce motion`.
struct SettingsPanelContent: View {
    @ObservedObject var state: AppState
    @State var selectedTab = 0
    /// Tab 悬停跟踪 — hover 时高亮对应 Tab。
    @State var tabHoveredIdx: Int? = nil

    @State var wipeState: WipeStage = .idle
    @State var wipeCountdown = 10
    @State var wipeTimer: Timer?

    enum WipeStage { case idle, counting, ready }

    @AppStorage("panel_size") var panelSize = "default"
    @AppStorage("dismiss_mode") var dismissMode = "clickOutside"
    @AppStorage("clipboard_monitor") var clipboardMonitor = false
    @AppStorage("history_disabled") var historyDisabled = false
    @AppStorage("max_history_count") var maxHistoryCount = 100
    @AppStorage("cache_enabled") var cacheEnabled = true
    @AppStorage("is_context_aware") var isContextAware = true
    @AppStorage("context_intensity") var contextIntensity = 2
    @AppStorage("custom_prompt_enabled") var customPromptEnabled = false
    @AppStorage("custom_prompt_text") var customPromptText = ""
    @AppStorage("dict_cache_enabled") var dictCacheEnabled = true
    @AppStorage("translation_temperature") var translationTemp: Double = 0.3
    @AppStorage("translation_maxTokens") var translationMaxTokens: Int = 1024
    @State var maxHistoryText = "100"
    @State var showAdvanced = false
    @State var recordingKey: String? = nil
    @State var refreshID = UUID()
    /// 快捷键录制的本地按键监听（生命周期由 GeneralTab 扩展管理）。
    @State var keyEventMonitor: Any? = nil
    /// 供应商参数保存防抖任务（拖动温度/Token 滑块时合并为一次保存，避免
    /// 每一步都触发全量 Keychain 加密写，审计 M7）。
    @State var providerSyncDebounceTask: Task<Void, Never>?

    // ── Animation State ──

    /// Triggers staggered card entrance on tab switch.
    @State var cardsVisible = false
    /// Tracks which cards are hovered for per-card scale feedback.
    @State var hoveredCardIndex: Int? = nil
    /// Pulse trigger for slider value labels (context intensity).
    @State var sliderPulseTrigger = UUID()
    /// Pulse trigger for temperature slider — separate from value so it only
    /// fires on discrete 0.05-step changes, not on every @AppStorage sync.
    @State var tempPulseTrigger = UUID()

    let tabItems: [(title: String, icon: String)] = [
        ("翻译", "arrow.triangle.2.circlepath"), ("API", "server.rack"),
        ("通用", "gearshape"), ("关于", "info.circle"),
    ]

    let contextSliders: [(String, String)] = [
        ("最低", "100 字符 — 极省 Token，但上下文理解较弱，适合短单词查询"),
        ("较低", "200 字符 — 轻度上下文，适合短语和简单句子翻译"),
        ("默认", "300 字符 — 推荐平衡点，兼顾准确度与 Token 消耗"),
        ("较高", "400 字符 — 增强上下文，适合段落翻译和代词指代"),
        ("最高", "500 字符 — 最强语境理解，适合专业文献和长难句，Token 消耗最高"),
    ]

    let features: [(icon: String, text: String)] = [
        ("globe", "多引擎流式翻译 — OpenAI · Claude · Gemini · 本地"),
        ("character.book.closed.fill", "智能词典查词 — 语境感知 · JSON 结构化"),
        ("rectangle.and.text.magnifyingglass", "OCR 屏幕识别 — 框选即译 · Vision 引擎"),
        ("arrow.triangle.swap", "原位替换 — 一键粘贴翻译结果"),
        ("brain.head.profile.fill", "双向上下文感知 — 精准术语与代词指代"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Layer 1: Tab 栏区域。
            //     AppKit 层已提供 windowBackground 实底画布，
            //     此处仅保留 Tab 胶囊自身结构。
            //     显式 .padding(.top, 28) 作为安全区保护垫：
            //     在 safeArea 归零的场景（全屏/刘海屏）下，
            //     强制保留至少 28pt 防止 Tab 栏暴冲到标题栏。
            VStack(spacing: 0) {
                if #available(macOS 26.0, *) {
                    GlassEffectContainer {
                        animatedTabBar
                            .frame(height: 48)
                            .padding(.horizontal, 2)
                            .padding(.top, 2)
                    }
                } else {
                    animatedTabBar
                        .frame(height: 48)
                        .padding(.horizontal, 2)
                        .padding(.top, 2)
                }
            }
            // v0.8：以 hairline 分割线替代「shadow 当分割线」——
            // 后者会在滚动时把上方内容染出灰边且参与误裁。
            .background(
                Rectangle().fill(AppTheme.hairline).frame(height: 0.5),
                alignment: .bottom
            )
            .padding(.top, 28)

            // ── 内容区。v0.8：移除 8pt 渐变 alpha mask ——
            //     它会把滚动进入顶部的第一行文字裁成半透明残影。
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 460, minHeight: 540)
        // 圆角由 AppKit 层的 NSVisualEffectView 统一控制（见 WindowConfig）。
        .accentColor(Color(nsColor: .controlAccentColor))
        // 显式 tint 确保分段选择器在窗口激活时显示系统强调色。
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
            debounceProviderSync { syncTemperatureToProvider(newValue) }
        }
        .onChange(of: translationMaxTokens) { _, newValue in
            debounceProviderSync { syncMaxTokensToProvider(newValue) }
        }
        .onChange(of: customPromptEnabled) { _, enabled in
            if enabled, customPromptText.isEmpty {
                customPromptText = defaultPrompt
            }
            syncCustomPromptToJSON()
        }
        .onChange(of: customPromptText) { _, _ in
            if customPromptEnabled { syncCustomPromptToJSON() }
        }
    }

    // ── Settings Persistence ──

    /// Load temperature/maxTokens from the current (non-built-in) provider into @AppStorage,
    /// ensuring the Settings panel shows what the translation engine actually uses.
    func loadSettingsFromProvider() {
        guard let provider = state.selectedProvider, !provider.isBuiltIn else { return }
        translationTemp = provider.temperature
        translationMaxTokens = provider.maxTokens
    }

    /// 供应商参数变更防抖：停止交互 300ms 后才落库，避免滑块拖动每步全量保存。
    func debounceProviderSync(_ block: @escaping @MainActor () -> Void) {
        providerSyncDebounceTask?.cancel()
        providerSyncDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            block()
        }
    }

    /// Push temperature change to the selected provider so TranslationActor uses it.
    func syncTemperatureToProvider(_ newValue: Double) {
        guard let provider = state.selectedProvider, !provider.isBuiltIn else { return }
        var updated = provider
        updated.temperature = newValue
        state.updateProvider(updated)
    }

    /// Push maxTokens change to the selected provider.
    func syncMaxTokensToProvider(_ newValue: Int) {
        guard let provider = state.selectedProvider, !provider.isBuiltIn else { return }
        var updated = provider
        updated.maxTokens = newValue
        state.updateProvider(updated)
    }

    /// Sync the two separate @AppStorage keys into the single JSON-encoded
    /// "custom_prompt" key that TranslationActor.buildHint() reads.
    func syncCustomPromptToJSON() {
        let cp = CustomPrompt(enabled: customPromptEnabled, text: customPromptText)
        if let data = try? JSONEncoder().encode(cp) {
            UserDefaults.standard.set(data, forKey: "custom_prompt")
        }
    }

    // MARK: - Tab Bar

    private var animatedTabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabItems.enumerated()), id: \.offset) { idx, item in
                LiquidGlassTabButton(
                    title: item.title,
                    icon: item.icon,
                    isSelected: selectedTab == idx,
                    isHovered: tabHoveredIdx == idx,
                    onHover: { tabHoveredIdx = $0 ? idx : nil },
                    action: {
                        withAnimation(AppTheme.Motion.tabSelect.resolveGated()) { selectedTab = idx }
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        // 容器内边距移入按钮内部，确保点击区域覆盖整个胶囊
        .padding(8)
        // macOS 26+: Liquid Glass Tab 栏表面；更早版本：实底回退
        .liquidGlassToolbar(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 2).padding(.top, 2)
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
        // ── v0.8.1 Bug 修复：必须保持默认边界裁剪。
        //     旧版的 `.scrollClipDisabled()` 允许滚动内容绘制到
        //     ScrollView 边界之外 —— 旧版靠顶部渐变 alpha mask 兜底，
        //     mask 移除后卡片会直接叠画到 Tab 栏与标题栏上层。
        //     卡片已实底化、无外溢阴影，无需解除裁剪。
    }

    // MARK: - API Tab

    private var apiTab: some View {
        ProviderSettingsView(state: state)
    }
}

// MARK: - Liquid Glass Tab Button

/// 设置页 Tab 按钮 — macOS 26+ Liquid Glass，旧版 bordered 回退。
/// 点击区域与外层胶囊轮廓完全对齐，自带 hover 高亮 + 按下 spring 反馈。
private struct LiquidGlassTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    @ViewBuilder
    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.fontSizeFine, weight: .medium))
                .scaleEffect(isSelected ? 1.1 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isSelected)
            Text(title)
                .font(.system(size: AppTheme.fontSizeFine, weight: isSelected ? .bold : .semibold))        }
        .foregroundColor(isSelected ? .primary : .secondary)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background {
            let capsule = Capsule()
            if #available(macOS 26.0, *) {
                // macOS 26+: Liquid Glass — 系统自动提供玻璃材质、悬停高亮、按压弹跳
                Color.clear
            } else {
                // macOS 15–25: bordered capsule 回退 + 手动 hover 高亮
                capsule
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
                    .overlay(capsule.strokeBorder(isSelected ? Color.accentColor.opacity(0.25) : .clear, lineWidth: 1))
                    .brightness(isHovered ? 0.06 : 0)
                    .animation(AppTheme.Motion.buttonHover.resolveGated(), value: isHovered)
            }
        }
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) { label }
                .buttonStyle(_LiquidGlassTabButtonStyle())
                .onHover(perform: onHover)
                .animation(AppTheme.Motion.tabSelect.resolveGated(), value: isSelected)
        } else {
            Button(action: action) { label }
                .buttonStyle(_BorderedTabButtonStyle())
                .onHover(perform: onHover)
                .animation(AppTheme.Motion.tabSelect.resolveGated(), value: isSelected)
        }
    }
}

/// macOS 26+ Liquid Glass tab 按钮样式。
/// 使用 `.glass` 提供系统级玻璃材质 + 自动悬停/按压动画。
@available(macOS 26.0, *)
private struct _LiquidGlassTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// macOS 15–25: Bordered capsule tab 按钮样式。
/// 带 spring 按压缩放 + 背景高亮反馈。
private struct _BorderedTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .background(
                configuration.isPressed
                    ? AnyShapeStyle(Color.primary.opacity(0.08))
                    : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

