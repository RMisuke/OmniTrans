import SwiftUI
import AppKit

// MARK: - 时间戳格式化器（P5）

/// P5: 复用 DateFormatter 单例，避免 body 重绘时反复创建格式化器。
/// 全部在 `@MainActor` 隔离下使用，规避 Swift 6 并发告警。
@MainActor
private enum PanelTimestampFormatters {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        f.timeZone = TimeZone.current
        f.locale = Locale.current
        return f
    }()

    static let legacy: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale.current
        return f
    }()
}

// MARK: - Floating Panel Content v6.5

struct FloatingPanelContent: View {
    @ObservedObject var state: AppState
    @Environment(TranslationSessionStore.self) private var session
    @Environment(OCRWarmupState.self) private var ocrWarmup

    @FocusState var isInputFocused: Bool
    @State var confirmClearHistory = false
    @State var historySearchText = ""
    @State var statusColor: StatusColor = .green
    @State var statusVisible = false
    @State var isBreathing = false
    @State var isProbingAPI = false
    @State var apiConnectionFailed = false
    @AppStorage("is_context_aware") var isContextAware = true
    @AppStorage("panel_size") var panelSize: String = "default"
    @State var panelVisible = false
    @State var brainPulse = false
    @State var pinned = false

    /// 底栏当前悬停按钮标识（用于 hover 高亮反馈）。
    @State var bottomBarHoveredBtn: String? = nil

    /// 动态测量的 Chrome 高度（topBar + inputCard + bottomBar + 间距）。
    /// 初始值 180 为估算回退，首次布局完成后通过 GeometryReader 更新。
    @State var chromeHeight: CGFloat = FloatingPanelLayout.chromeInitialEstimate

    /// 标记 Chrome 是否已完成首次测量，防止窗口高度变化触发重复测量导致布局震荡。
    @State var chromeMeasured = false

    /// 动态高度防抖任务 — 流式输出时合并高频更新。
    @State var heightDebounceTask: Task<Void, Never>?

    /// API 连通性探测节流：上次探测时间戳。
    /// 两次探测间隔不得小于 `FloatingPanelLayout.apiProbeMinInterval`（30s）。
    @State var lastProbeTime: Date = .distantPast

    /// 输入文本：直接绑定到 session.inputText，确保 opt+D 划词后
    /// 原文立即同步到输入框，不再依赖 onAppear/onChange 时序。
    private var inputText: Binding<String> {
        Binding(
            get: { session.inputText },
            set: { session.inputText = $0 }
        )
    }

    enum StatusColor { case green, yellow, red }

    // MARK: - Mode Detection

    /// 当前是否有历史记录（无划词 + 无输入 → 显示历史搜索）。
    private var showHistorySearch: Bool {
        inputText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && session.translatedText.isEmpty
        && session.dictionaryEntry == nil
    }

    /// 模式标签文本。词典模式下始终显示"词典"（包括查词完成后）。
    var modeLabel: String {
        (session.isDictionaryMode || session.dictionaryEntry != nil) ? "词典" : "翻译"
    }

    /// 工作区显示模式 — 驱动跨 mode 切换的动画。
    /// Formats the UTC SQLite timestamp to the user's local timezone.
    /// P5: 复用静态格式化器，消除重绘时的重复创建开销。
    @MainActor
    var formattedCacheTimestamp: String {
        if let date = PanelTimestampFormatters.iso.date(from: session.cacheTimestamp) {
            return PanelTimestampFormatters.display.string(from: date)
        }
        // Fallback: legacy SQLite CURRENT_TIMESTAMP (UTC, no timezone info)
        if let date = PanelTimestampFormatters.legacy.date(from: session.cacheTimestamp) {
            return PanelTimestampFormatters.display.string(from: date)
        }
        return session.cacheTimestamp
    }

    enum DisplayMode { case history, translating, error, dictionary, translation, empty }
    var displayMode: DisplayMode {
        if showHistorySearch { return .history }
        if session.isTranslating && session.translatedText.isEmpty && session.dictionaryEntry == nil { return .translating }
        if session.errorMessage != nil { return .error }
        if session.dictionaryEntry != nil { return .dictionary }
        if !session.translatedText.isEmpty { return .translation }
        return .empty
    }

    // MARK: - Dynamic Input Height

    /// 精确单行高度，使用 `NSFont` 字型度量。
    var lineHeight: CGFloat {
        let nsFont = NSFont.systemFont(ofSize: AppTheme.fontSizeBody)
        return ceil(nsFont.ascender + abs(nsFont.descender) + nsFont.leading)
    }

    /// NSTextView (`TextEditor`) 的默认 `textContainerInset` 垂直分量。
    var textContainerVerticalInset: CGFloat {
        FloatingPanelLayout.textContainerVerticalInset
    }

    /// 计算输入框动态行高。
    /// 正常翻译模式：最少 1 行，最多 3 行（内容自适应）。
    var inputEditorHeight: (min: CGFloat, max: CGFloat) {
        let lh = lineHeight
        let ins = textContainerVerticalInset
        if session.isDictionaryMode || session.dictionaryEntry != nil {
            return (lh + ins, lh + ins)  // 1 行锁定（词典模式）
        }
        if showHistorySearch {
            return (lh + ins, lh + ins)  // 1 行（搜索模式）
        }
        return (lh + ins, lh * 3 + ins)  // 1–3 行动态（翻译输入）
    }

    // MARK: - Dynamic Height (min 480, max 800)

    /// 动态模式下的窗口高度边界 — 统一来源 `FloatingPanel`。
    static let dynamicMinH: CGFloat = FloatingPanel.dynamicMinHeight
    static let dynamicMaxH: CGFloat = FloatingPanel.dynamicMaxHeight

    /// 文本可用布局宽度。
    var textLayoutWidth: CGFloat {
        FloatingPanelLayout.textLayoutWidth
    }

    /// 译文/词典正文单行高度（基于 15pt 系统字体）。
    var bodyLineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 15)
        return ceil(font.ascender + abs(font.descender) + font.leading)
    }

    /// 计算译文所需窗口高度并在动态模式下应用。
    ///
    /// ## 防抖策略
    /// - 流式输出时 (`debounce = true`)：50ms 防抖合并高频 token 更新。
    /// - 非流式输出时 (`debounce = false`)：无延迟，即时计算。
    ///
    /// ## 设计要点
    /// - 不在调度时捕获状态快照，而是在 Task 执行时直接从 `@MainActor` session 读取最新值。
    ///   前一个 Task 已被取消时不会执行，因此存活 Task 读取的一定是最新状态。
    /// - 相比快照方式，闭包捕获更轻量（仅捕获 `currentChromeH`），减少每次 token 到达的开销。
    func scheduleHeightUpdate(debounce: Bool = false) {
        guard panelSize == "dynamic" else { return }
        guard !AppState.isUserDraggingWindow else { return }

        heightDebounceTask?.cancel()
        let delay: UInt64 = debounce ? 50_000_000 : 0
        let currentChromeH = chromeHeight

        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            let calculator = ContentHeightCalculator(
                bodyFontSize: 15,
                layoutWidth: textLayoutWidth,
                minHeight: Self.dynamicMinH,
                maxHeight: Self.dynamicMaxH,
                chromeHeight: currentChromeH
            )

            let target: CGFloat

            switch displayMode {
            case .history:
                target = calculator.defaultTargetHeight

            case .translating:
                target = session.isTranslating
                    ? calculator.streamingTargetHeight(currentText: session.translatedText)
                    : calculator.defaultTargetHeight

            case .translation:
                target = calculator.translationTargetHeight(text: session.translatedText)

            case .dictionary:
                if let entry = session.dictionaryEntry, entry.isWord {
                    target = calculator.dictionaryTargetHeight(
                        entry: entry,
                        fromCache: session.isFromLocalCache,
                        modelName: session.cachedModelName
                    )
                } else {
                    target = calculator.defaultTargetHeight
                }

            case .error, .empty:
                target = calculator.defaultTargetHeight
            }

            FloatingWindowManager.shared.updateHeight(target, animated: true)
        }
        heightDebounceTask = task
    }

    var body: some View {
        VStack(spacing: 0) {
            if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    VStack(spacing: 0) {
                        topBar
                        inputCard
                            .padding(.bottom, 8)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    inputCard
                        .padding(.bottom, 8)
                }
            }
            middleArea
                .frame(maxHeight: .infinity)
                .animation(AppTheme.Motion.contentSwap.resolveGated(), value: displayMode)
                .background(alignment: .center) { chromeHeightMeasurer }
            if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    VStack(spacing: 0) {
                        bottomBar
                            .padding(.top, 4)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    bottomBar
                        .padding(.top, 4)
                }
            }
        }
        .frame(minWidth: FloatingPanelLayout.panelWidth,
               idealWidth: FloatingPanelLayout.panelIdealWidth,
               minHeight: FloatingPanelLayout.panelMinHeight)
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
        .accentColor(Color(nsColor: .controlAccentColor))
        .scaleEffect(panelVisible ? 1 : 0.97)
        .opacity(panelVisible ? 1 : 0)
        .offset(y: panelVisible ? 0 : 6)
        .animation(AppTheme.Motion.panelAppear.resolveGated(), value: panelVisible)
        .onAppear {
            pinned = FloatingWindowManager.shared.isPinned
            updateStatusFromSession()
            probeAPIConnectivity()
            HotkeyManager.shared.preConnectCurrentProvider()
            scheduleHeightUpdate()
            withAnimation(AppTheme.Motion.panelAppear.resolveGated()) {
                panelVisible = true
            }
        }
        .onChange(of: state.selectedProviderID) { _, _ in probeAPIConnectivity() }
        .onChange(of: session.isTranslating) { _, newValue in
            if !newValue {
                probeAPIConnectivity()
                updateStatusFromSession()  // 流式结束 → 绿灯
            } else {
                updateStatusFromSession()  // 开始翻译 → 黄灯
            }
        }
        .onChange(of: session.errorMessage) { _, _ in updateStatusFromSession() }
        .onChange(of: session.translatedText) { _, _ in
            updateStatusFromSession()
            scheduleHeightUpdate(debounce: session.isTranslating)
        }
        .onChange(of: session.dictionaryEntry?.word) { _, _ in
            updateStatusFromSession()
            scheduleHeightUpdate()
        }
        .onChange(of: session.inputText) { _, _ in
            scheduleHeightUpdate()
        }
        .onChange(of: panelSize) { _, newValue in
            if newValue == "dynamic" {
                scheduleHeightUpdate()
            } else {
                let h = FloatingPanel.shared.heightForMode(newValue)
                FloatingWindowManager.shared.updateHeight(h, animated: true)
            }
        }
    }

    // MARK: - Chrome Height Measurement

    /// 通过 GeometryReader 在首次布局时测量 Chrome 高度。
    /// Chrome = topBar + inputCard + bottomBar + 间距。
    /// **一次性测量**：首次布局完成后记录，此后无论窗口高度如何变化都不再重新测量，
    /// 避免 `测量 → 更新窗口高度 → 内容高度变化 → 再次测量` 的布局震荡循环。
    @ViewBuilder
    private var chromeHeightMeasurer: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    guard !chromeMeasured else { return }
                    updateChromeHeight(middleAreaHeight: geometry.size.height)
                }
        }
    }

    /// 根据 middleArea 实测高度计算并锁定 Chrome 高度。
    /// 范围守卫 [120, 300] 确保只接受有效值，拒绝动画过渡期的异常数据。
    /// `chromeMeasured` 标记确保该方法**最多执行一次**，切断布局反馈循环。
    func updateChromeHeight(middleAreaHeight: CGFloat) {
        let windowH = FloatingWindowManager.shared.currentHeight
        let computed = windowH - middleAreaHeight
        if computed >= FloatingPanelLayout.chromeMin && computed <= FloatingPanelLayout.chromeMax {
            chromeHeight = computed
            chromeMeasured = true
        }
    }

    // MARK: - Status Indicator

    func updateStatusFromSession() {
        // 状态互斥：红 > 黄 > 绿，绝不同时出现两种颜色
        if session.errorMessage != nil {
            // 有错误 → 红灯常亮（最高优先级）
            isBreathing = false
            statusColor = .red
        } else if apiConnectionFailed {
            // API 连接失败 → 红灯常亮
            isBreathing = false
            statusColor = .red
        } else if isProbingAPI || session.isTranslating {
            // 正在探测或翻译中 → 黄灯闪烁（中间态）
            isBreathing = true
            statusColor = .yellow
        } else {
            // 空闲 / 上次探测成功 / 翻译完成 → 绿灯常亮
            isBreathing = false
            statusColor = .green
        }
        statusVisible = true
    }

    /// Runs an async API connectivity probe against the current provider.
    /// 带节流控制：两次探测间隔不得小于 `apiProbeMinInterval`（30s）。
    func probeAPIConnectivity() {
        guard let provider = state.selectedProvider,
              provider.kind != .macOSNative
        else {
            apiConnectionFailed = false
            updateStatusFromSession()
            return
        }

        // P3-#13: API 探测节流 — 避免 onChange 链式触发高频重复探测
        let now = Date()
        guard now.timeIntervalSince(lastProbeTime) >= FloatingPanelLayout.apiProbeMinInterval else { return }
        lastProbeTime = now

        isProbingAPI = true
        apiConnectionFailed = false
        updateStatusFromSession()

        Task { [provider] in
            let result = await APITestService.testConnection(for: provider)
            await MainActor.run {
                self.isProbingAPI = false
                switch result {
                case .success:
                    self.apiConnectionFailed = false
                case .failure:
                    self.apiConnectionFailed = true
                }
                self.updateStatusFromSession()
            }
        }
    }

    // setStatus removed — status is now always visible (green/red steady, yellow blinking)

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            // ── 左侧: App 图标 + 模式标签 + 状态灯 ──
            appIconView
            Text(modeLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
            statusIndicator
            warmupProgressBar

            Spacer()

            // ── 供应商选择器 ──
            providerMenu

            // ── 图钉按钮 ──
            pinButton
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - App Icon

    private var appIconView: some View {
        Group {
            if let path = Bundle.main.path(forResource: "icon", ofType: "icns"),
               let icon = NSImage(contentsOfFile: path) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - OCR Warmup Progress Bar

    @ViewBuilder
    private var warmupProgressBar: some View {
        if ocrWarmup.isWarmingUp {
            HStack(spacing: 4) {
                ProgressView(value: ocrWarmup.progress)
                    .frame(width: 36)
                    .tint(.accentColor)
                Text("OCR 引擎预热中…")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
            .animation(.easeInOut(duration: 0.35), value: ocrWarmup.isWarmingUp)
        }
    }

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        let color: Color = {
            switch statusColor {
            case .green:  return Color(red: 0.157, green: 0.784, blue: 0.251)
            case .yellow: return Color(red: 1.000, green: 0.800, blue: 0.000)  // #FFCC00 — vibrant neon amber
            case .red:    return Color(red: 1.000, green: 0.373, blue: 0.341)
            }
        }()

        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(statusVisible ? (isBreathing ? 0.35 : 1) : 0)
            .scaleEffect(isBreathing ? 1.5 : 1.0)
            .shadow(color: color.opacity(statusVisible ? (isBreathing ? 0.9 : 0.5) : 0),
                    radius: isBreathing ? 12 : 5, x: 0, y: 0)
            .animation(AppTheme.Motion.statusFade.resolveGated(), value: statusVisible)
            .animation(isBreathing ? AppTheme.Motion.statusBreathing.repeatForever(autoreverses: true) : .default, value: isBreathing)
    }

    // MARK: - Provider Menu

    private var providerMenu: some View {
        let providers = state.enabledProviders
        let isShowingDict = session.isDictionaryMode || session.dictionaryEntry != nil
        let currentID = isShowingDict ? (state.dictProviderID ?? state.selectedProviderID) : state.selectedProviderID
        let currentProviderName: String = {
            if isShowingDict, let dictID = state.dictProviderID {
                return providers.first(where: { $0.id == dictID })?.name ?? "API"
            }
            return state.selectedProvider?.name ?? "API"
        }()

        return Group {
            if !providers.isEmpty {
                Menu {
                    ForEach(providers) { p in
                        Button {
                            if isShowingDict {
                                state.dictProviderID = p.id
                                ProviderStorageManager.saveDictProviderID(p.id)
                            } else {
                                state.selectedProviderID = p.id
                                ProviderStorageManager.saveSelectedProviderID(p.id)
                            }
                            probeAPIConnectivity()
                        } label: {
                            HStack {
                                if currentID == p.id { Image(systemName: "checkmark") }
                                Text("\(p.name) · \(p.modelName)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu").font(.system(size: 10))
                        Text(currentProviderName)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .liquidGlassToolbar(in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .frame(minWidth: 100, maxWidth: 140)
            }
        }
    }

    // MARK: - Pin Button

    private var pinButton: some View {
        return Button {
            withAnimation(AppTheme.Motion.pinToggle.resolveGated()) {
                FloatingWindowManager.shared.isPinned.toggle()
                pinned = FloatingWindowManager.shared.isPinned
            }
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundColor(pinned ? .accentColor : .secondary)
                .rotationEffect(.degrees(pinned ? 45 : 0))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pinned ? "取消置顶" : "置顶窗口")
        .animation(AppTheme.Motion.pinToggle.resolveGated(), value: pinned)
    }

    // MARK: - Input Card

    private var inputCard: some View {
        VStack(spacing: 0) {
            TextEditor(text: inputText)
                .font(.system(size: AppTheme.fontSizeBody))
                .scrollContentBackground(.hidden)
                .frame(minHeight: inputEditorHeight.min, maxHeight: inputEditorHeight.max)
                .animation(AppTheme.Motion.inputExpand.resolveGated(), value: inputEditorHeight.max)
                .focused($isInputFocused)
                .onKeyPress(.return) {
                    // Enter triggers translation immediately.
                    commitTranslation()
                    return .handled
                }
                .overlay(alignment: .topLeading) {
                    if inputText.wrappedValue.isEmpty {
                        Text("输入内容按下 Enter 开始翻译")
                            .font(.system(size: AppTheme.fontSizeBody))
                            .foregroundColor(.secondary.opacity(0.4))
                            .padding(.top, 2).padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !inputText.wrappedValue.isEmpty {
                        clearInputButton
                    }
                }
        }
        .padding(AppTheme.spaceMD)
        .background(
            RoundedRectangle(cornerRadius: FloatingPanelLayout.inputSurfaceRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        // v0.8.1：聚焦时强调色描边渐显（focus ring），失焦回 hairline。
        // 描边代替投影表达层级 —— 哑光画布规范。
        .overlay(
            RoundedRectangle(cornerRadius: FloatingPanelLayout.inputSurfaceRadius, style: .continuous)
                .strokeBorder(
                    isInputFocused ? AppTheme.accentAction.opacity(0.55) : AppTheme.MaterialPolicy.cardStroke,
                    lineWidth: isInputFocused ? 1.5 : 1
                )
                .animation(AppTheme.Motion.buttonHover.resolveGated(), value: isInputFocused)
        )
        .padding(.horizontal, FloatingPanelLayout.contentHorizontalInset).padding(.vertical, 4)
    }

    private var clearInputButton: some View {
        Button {
            state.resetForNew(text: "")
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(AppTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .padding(4)
        .transition(.opacity.animation(AppTheme.Motion.clearFade.resolve()))
        .animation(AppTheme.Motion.clearFade.resolveGated(), value: inputText.wrappedValue.isEmpty)
    }

    // MARK: - Middle Area (flexible)

    @ViewBuilder
    private var middleArea: some View {
        if showHistorySearch {
            historySearchArea
                .transition(FloatingPanelLayout.defaultContentTransition)
        } else if session.isTranslating && session.translatedText.isEmpty && session.dictionaryEntry == nil {
            translatingView
                .transition(FloatingPanelLayout.defaultContentTransition)
        } else if let err = session.errorMessage {
            errorView(err)
                .transition(FloatingPanelLayout.defaultContentTransition)
        } else if let entry = session.dictionaryEntry {
            dictionaryResultView(entry)
                .transition(FloatingPanelLayout.defaultContentTransition)
        } else if !session.translatedText.isEmpty {
            translationResultView
                .transition(FloatingPanelLayout.defaultContentTransition)
        } else {
            Spacer(minLength: 0)
        }
    }

    // MARK: - History Search (no text selected mode)

    private var historySearchArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.accentColor)
                TextField("搜索翻译历史…", text: $historySearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if confirmClearHistory {
                    HStack(spacing: 4) {
                        Button {
                            state.clearHistory()
                            confirmClearHistory = false
                        } label: {
                            Text("确认删除")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.red))
                        }
                        .buttonStyle(PressableButtonStyle())
                        Button("取消") { confirmClearHistory = false }
                            .font(.system(size: 11))
                            .buttonStyle(PressableButtonStyle())
                    }
                } else {
                    Button {
                        confirmClearHistory = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            confirmClearHistory = false
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash").font(.system(size: 10))
                            Text("清除历史").font(.system(size: 11))
                        }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            // macOS 26+: Liquid Glass 搜索栏表面；更早版本：实底 + 强调描边
            .liquidGlassToolbar(in: RoundedRectangle(cornerRadius: FloatingPanelLayout.surfaceRadius, style: .continuous))
            .padding(.bottom, 8)

            // Filtered history list
            let filtered = state.translationHistory.filter {
                historySearchText.isEmpty
                || $0.input.localizedCaseInsensitiveContains(historySearchText)
                || (!$0.isDictionaryMode
                    && $0.output.localizedCaseInsensitiveContains(historySearchText))
            }

            if !filtered.isEmpty {
                ScrollView {
                    LazyVStack(spacing: FloatingPanelLayout.listRowSpacing) {
                        ForEach(filtered) { entry in
                            historyCard(entry)
                        }
                    }
                    // v0.8.1：底部预留滚动指示器空间，避免末行被遮挡。
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 250)
                // v0.8.1 Bug 修复：删除顶部渐变 alpha mask ——
                // 它把滚动进入顶端的第一张卡片文字裁成残影。
                // 改靠 ScrollView 默认边界自然裁剪。
            } else {
                Text(historySearchText.isEmpty ? "暂无翻译历史" : "无匹配结果")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func historyCard(_ entry: HistoryEntry) -> some View {
        Button {
            // Restore cached input/output directly — no API call unless
            // the entry has no output (failed translation).
            state.recallHistoryEntry(entry)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.input)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    Spacer()
                    if entry.isDictionaryMode {
                        Text("词典")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                if !entry.isDictionaryMode {
                    Text(entry.output)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(entry.providerName)
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                    Spacer()
                    Text(formattedTime(entry.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.spaceMD)
            .background(
                RoundedRectangle(cornerRadius: FloatingPanelLayout.surfaceRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FloatingPanelLayout.surfaceRadius, style: .continuous)
                    .strokeBorder(AppTheme.MaterialPolicy.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Translating

    private var translatingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().scaleEffect(0.8)
            Text(session.isDictionaryMode ? "正在查询词典…" : "正在翻译…")
                .font(.system(size: 13)).foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Error

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24)).foregroundColor(.orange)
            Text(error).font(.system(size: 13)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)
            Button("重试") { state.retryTranslate() }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Translation Result

    private var translationResultView: some View {
        ScrollView {
            Text(session.translatedText)
                .font(.system(size: 15))
                .textSelection(.enabled)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.spaceMD)
        .background(
            RoundedRectangle(cornerRadius: FloatingPanelLayout.surfaceRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FloatingPanelLayout.surfaceRadius, style: .continuous)
                .strokeBorder(AppTheme.MaterialPolicy.cardStroke, lineWidth: 1)
        )
        .padding(.horizontal, FloatingPanelLayout.contentHorizontalInset)
        .frame(minHeight: 80, maxHeight: panelSize == "dynamic" ? .infinity : 280)
    }

    // MARK: - Dictionary Result

    private func dictionaryResultView(_ entry: DictionaryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.word).font(.system(size: 20, weight: .bold))
                    if !entry.phonetic.isEmpty {
                        Text(entry.phonetic)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if session.isFromLocalCache {
                        HStack(spacing: 4) {
                            Image(systemName: "cylinder.split.1x2.fill")
                                .font(.system(size: 11))
                            Text("本地词典")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                    }
                }
                Rectangle().fill(.quaternary).frame(height: 1)

                ForEach(entry.definitions) { def in
                    HStack(alignment: .top, spacing: 8) {
                        Text(def.pos)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .padding(.top, 1)
                        Text(def.meaning).font(.system(size: 13))
                    }
                }

                if !entry.examples.isEmpty {
                    Rectangle().fill(.quaternary).frame(height: 1)
                    ForEach(entry.examples) { ex in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ex.en).font(.system(size: 12)).italic()
                            Text(ex.zh).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }

                // ── Footer: model + timestamp ──
                if session.isFromLocalCache && !session.cachedModelName.isEmpty {
                    Rectangle().fill(.quaternary).frame(height: 1)
                    Text("由 \(session.cachedModelName) 生成于 \(formattedCacheTimestamp)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(AppTheme.spaceMD)
        .background(
            RoundedRectangle(cornerRadius: FloatingPanelLayout.surfaceRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FloatingPanelLayout.surfaceRadius, style: .continuous)
                .strokeBorder(AppTheme.MaterialPolicy.cardStroke, lineWidth: 1)
        )
        .padding(.horizontal, FloatingPanelLayout.contentHorizontalInset)
        .frame(minHeight: 80, maxHeight: panelSize == "dynamic" ? .infinity : 280)
    }

    // MARK: - Bottom Bar (macOS 26 Liquid Glass)

    private var bottomBar: some View {
        HStack(spacing: AppTheme.spaceXS) {
            // ── 目标语言选择器 (globe + label) ──
            Menu {
                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in
                    Button {
                        state.targetLang = l
                    } label: {
                        HStack {
                            if state.targetLang == l { Image(systemName: "checkmark") }
                            Text(l.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                    Text(state.targetLang.rawValue)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
                .brightness(bottomBarHoveredBtn == "lang" ? 0.12 : 0)
                .scaleEffect(bottomBarHoveredBtn == "lang" ? 1.04 : 1.0)
                .animation(AppTheme.Motion.buttonHover.resolveGated(), value: bottomBarHoveredBtn == "lang")
            }
            .menuStyle(.borderlessButton)
            .frame(height: 26)
            .liquidGlassButton()
            .onHover { hovered in bottomBarHoveredBtn = hovered ? "lang" : nil }

            // ── 上下文感知开关 — micro-pulse on toggle ──
            Button {
                withAnimation(AppTheme.Motion.brainPulseAnim.resolveGated()) { brainPulse = true }
                isContextAware.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(AppTheme.Motion.brainPulseAnim.resolveGated()) { brainPulse = false }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .scaleEffect(brainPulse ? 1.25 : 1.0)
                    Text(isContextAware ? "context on" : "context off")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(isContextAware ? AppTheme.accentAction : AppTheme.textCaptionGray)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
                .brightness(bottomBarHoveredBtn == "ctx" ? 0.12 : 0)
                .scaleEffect(bottomBarHoveredBtn == "ctx" ? 1.04 : 1.0)
                .animation(AppTheme.Motion.buttonHover.resolveGated(), value: bottomBarHoveredBtn == "ctx")
            }
            .frame(height: 22)
            .liquidGlassButton()
            .onHover { hovered in bottomBarHoveredBtn = hovered ? "ctx" : nil }
            .help(isContextAware ? "上下文感知已启用" : "上下文感知已关闭")

            Spacer()

            // ── 复制 ──
            bottomBarIconBtn("doc.on.doc", "拷贝结果", id: "copy") { copyResult() }

            // ── TTS ──
            bottomBarIconBtn("speaker.wave.2", "朗读结果", id: "tts") { speakResult() }

            // ── 主操作按钮 ──
            let hasResult = !session.translatedText.isEmpty || session.dictionaryEntry != nil
            Button {
                if hasResult { state.retryTranslate() } else { commitTranslation() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                    Text(hasResult ? (session.dictionaryEntry != nil || session.isDictionaryMode ? "重新查词" : "重新翻译") : modeLabel)
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .frame(height: 26)
            .liquidGlassProminentButton()
            .layoutPriority(1)
            .disabled(inputText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isTranslating)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        // macOS 26+: Liquid Glass 工具栏表面；更早版本：实底回退
        .liquidGlassToolbar(in: RoundedRectangle(cornerRadius: AppTheme.hudCornerRadius, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    /// 底栏图标按钮 — 统一高度 + hover/press 反馈。
    private func bottomBarIconBtn(_ icon: String, _ help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .frame(width: 28, height: 26)
        .background {
            let shape = RoundedRectangle(cornerRadius: AppTheme.radiusSM, style: .continuous)
            Group {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    AppTheme.MaterialPolicy.cardBackground
                        .overlay(shape.strokeBorder(AppTheme.MaterialPolicy.cardStroke))
                        .clipShape(shape)
                }
            }
            .brightness(bottomBarHoveredBtn == id ? 0.12 : 0)
            .scaleEffect(bottomBarHoveredBtn == id ? 1.04 : 1.0)
            .animation(AppTheme.Motion.buttonHover.resolveGated(), value: bottomBarHoveredBtn == id)
        }
        .onHover { hovered in bottomBarHoveredBtn = hovered ? id : nil }
        .disabled(session.translatedText.isEmpty && session.dictionaryEntry == nil)
    }

    // MARK: - Helpers

    private func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    // MARK: - Actions

    private func commitTranslation() {
        let trimmed = inputText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.inputText = trimmed
        state.translate()
    }

    private func copyResult() {
        let text: String
        if let entry = session.dictionaryEntry {
            text = entry.word
        } else if !session.translatedText.isEmpty {
            text = session.translatedText
        } else {
            return
        }
        // 抑制自身写入，避免剪贴板监控把拷贝结果当作新划词再翻译（审计 M9）
        ClipboardMonitor.shared.suppressNext = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func speakResult() {
        let text: String
        if let entry = session.dictionaryEntry {
            text = entry.word
        } else if !session.translatedText.isEmpty {
            text = session.translatedText
        } else {
            return
        }
        TTSManager.shared.speakNative(text: text)
    }
}
