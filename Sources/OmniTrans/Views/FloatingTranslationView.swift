import SwiftUI

// MARK: - App Icon Helper

private func appIcon(size: CGFloat = 18) -> NSImage {
    if let path = Bundle.main.path(forResource: "icon", ofType: "icns"),
       let icon = NSImage(contentsOfFile: path) {
        let resized = NSImage(size: NSSize(width: size, height: size))
        resized.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                  from: .zero, operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }
    return NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: nil)!
}

// MARK: - Floating Display Mode

/// V0.6: Drives the workspace area below the input card.
enum FloatingDisplayMode {
    /// Empty input → search bar + history cards.
    case history
    /// Processing text → input card + streaming result card.
    case translation
    /// Single‑word lookup → 1‑line input + dictionary card.
    case dictionary
}

// MARK: - Floating Translation View (V0.6 Central Workstation)

/// Main floating panel — "Solid Top, Thick Bottom" macOS 26 native layout.
///
/// V0.6: The Floating Panel is now an all-in-one **Central Workstation**.
/// - **Editable Input Card**: dynamic-height TextEditor (3–5 lines, dict=1 line).
/// - **History Mode**: search bar + clear button + expandable history cards.
/// - **Translation Mode**: streaming text output.
/// - **Dictionary Mode**: compact input + structured dictionary card.
/// - **Pin Window**: toggleable `.screenSaver` level via SF Symbol pin button.
struct FloatingTranslationView: View {
    @ObservedObject var state: AppState
    @Environment(TranslationSessionStore.self) private var session
    @AppStorage("panel_size") private var panelSize = "default"
    @AppStorage("is_context_aware") private var isContextAware = true
    @AppStorage("history_disabled") private var historyDisabled = false

    // MARK: - Mode derivation

    @State private var displayMode: FloatingDisplayMode = .history

    /// Pin state — when true, panel floats above all windows and ignores dismissal.
    @State private var isPinned = false

    /// `true` while async history is loading.  The workspace shows
    /// a loading indicator instead of "暂无翻译记录" during this window.
    @State private var isHistoryLoading = true
    /// Incremented each time the panel appears — drives `.task(id:)` so
    /// history is reloaded even when the hosting view stays in the hierarchy.
    @State private var appearGeneration = 0

    // MARK: - Dynamic panel sizing (panelSize == "dynamic")

    /// Current dynamic panel height target (only used when panelSize == "dynamic").
    @State private var dynamicPanelHeight: CGFloat = 460
    /// Last computed text pixel height — prevents redundant identical updates.
    @State private var lastTextPixelHeight: CGFloat = 0

    /// Chrome height: everything except the workspace area.
    private let chromeHeight: CGFloat = 205
    /// Available width for text layout inside the result card (panel 420 − contentStack 20 − card padding 8 − text padding 28).
    private let textAvailableWidth: CGFloat = 364
    /// Translation text font (must match StreamingTextView: AppTheme.fontSizeBody = 17 pt).
    private let textFont = NSFont.systemFont(ofSize: AppTheme.fontSizeBody)
    /// Paragraph style matching StreamingTextView's `.lineSpacing(4)`.
    private let textParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        return p
    }()
    /// Internal padding inside StreamingTextView (HStack .v 8 × 2 + outer .v 6 × 2).
    private let textInternalVPad: CGFloat = 28
    /// Min height when dynamic mode is active (matches "default" preset).
    private var dynamicMinH: CGFloat { FloatingPanel.shared.heightForMode("default") }
    /// Max height when dynamic mode is active.
    private var dynamicMaxH: CGFloat { FloatingPanel.maxHeight }

    /// Whether current session is in dictionary mode.
    private var isDict: Bool { session.isDictionaryMode || session.dictionaryEntry?.isWord == true }
    private var isNativeDict: Bool {
        guard let id = state.dictProviderID else { return true }
        return state.enabledProviders.first(where: { $0.id == id })?.kind == .macOSNative
    }
    private var activeProvider: APIProvider? {
        guard isDict, let id = state.dictProviderID,
              let p = state.enabledProviders.first(where: { $0.id == id })
        else { return state.selectedProvider }
        return p
    }
    private var providerName: String {
        activeProvider?.name ?? "API"
    }
    private var currentProviderID: UUID? { isDict ? state.dictProviderID : state.selectedProviderID }

    // MARK: - History state

    @State private var historySearchText: String = ""
    @State private var expandedHistoryItemId: UUID? = nil
    @State private var localInputText: String = ""

    private var filteredHistoryItems: [HistoryEntry] {
        let items = state.translationHistory
        if historySearchText.isEmpty {
            return items.sorted(by: { $0.timestamp > $1.timestamp })
        }
        return items.filter { item in
            if item.isDictionaryMode {
                let visibleText = dictionaryVisibleText(from: item.output)
                return visibleText.localizedCaseInsensitiveContains(historySearchText)
            } else {
                return item.input.localizedCaseInsensitiveContains(historySearchText) ||
                       item.output.localizedCaseInsensitiveContains(historySearchText)
            }
        }.sorted(by: { $0.timestamp > $1.timestamp })
    }

    private func dictionaryVisibleText(from jsonString: String) -> String {
        guard let entry = DictionaryEntry.parse(from: jsonString, word: "") else { return jsonString }
        var parts: [String] = []
        if !entry.phonetic.isEmpty { parts.append(entry.phonetic) }
        for def in entry.definitions { parts.append(def.meaning) }
        for ex in entry.examples { parts.append(ex.en); parts.append(ex.zh) }
        return parts.joined(separator: " ")
    }

    // MARK: - Panel height

    private func panelHeightForMode(_ mode: FloatingDisplayMode) -> CGFloat {
        switch mode {
        case .history:     return 460
        case .translation:
            return panelSize == "dynamic" ? dynamicPanelHeight : 500
        case .dictionary:  return 420
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            dragBar
            headerBar
            if session.showPermissionHint { permissionBlock }
            else { contentStack }
            bottomBar
            resizeGrip
        }
        .frame(minWidth: 340, idealWidth: 420)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accentColor(AppTheme.accentAction)
        .ignoresSafeArea(.container, edges: .top)
        .animationsGated()
        .onKeyPress(.escape) {
            guard !isPinned else { return .ignored }
            FloatingPanel.shared.hide()
            return .handled
        }
        .onChange(of: session.inputText) { _, v in
            localInputText = v
            session.detectedIsWord = WordDetector.isWord(v)
        }
        .onChange(of: displayMode) { _, mode in
            FloatingPanel.shared.updateHeight(panelHeightForMode(mode))
        }
        .onChange(of: session.isDictionaryMode) { _, isDict in
            if isDict { displayMode = .dictionary }
        }
        .onChange(of: session.isTranslating) { _, translating in
            if translating {
                displayMode = .translation
                // Reset dynamic height state for a new translation
                if panelSize == "dynamic" {
                    dynamicPanelHeight = dynamicMinH
                    lastTextPixelHeight = 0
                }
            } else {
                // Translation just completed — one-shot: compute final height
                if panelSize == "dynamic", displayMode == .translation {
                    updateDynamicHeight(for: session.translatedText, isStreaming: false)
                }
            }
        }
        .onChange(of: session.translatedText) { _, text in
            guard !text.isEmpty, !session.isDictionaryMode else { return }
            if !session.isTranslating {
                displayMode = .translation
            }
            // Streaming: smooth animated expansion via measured pixel height.
            // One-shot final height is handled by onChange(of: session.isTranslating).
            updateDynamicHeight(for: text, isStreaming: true)
        }
        .onChange(of: session.dictionaryEntry) { _, entry in
            if entry?.isWord == true { displayMode = .dictionary }
        }
        .task(id: appearGeneration) {
            // Reload history fresh each time the panel appears.
            // `id: appearGeneration` forces SwiftUI to restart this task even
            // when the hosting NSView stays in the window hierarchy across
            // orderOut → makeKeyAndOrderFront cycles.
            isHistoryLoading = true
            await HistoryActor.shared.loadFromDisk()
            let loaded = ProviderStorageManager.loadHistory()
            state.translationHistory = loaded
            isHistoryLoading = false
            DispatchQueue.main.async {
                if self.displayMode == .history {
                    FloatingPanel.shared.updateHeight(panelHeightForMode(.history), animate: true)
                }
            }
        }
        .onAppear {
            appearGeneration += 1
            forceHistoryLoad()
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingPanelDidShow)) { _ in
            // Panel was reshown via orderOut → makeKeyAndOrderFront.
            // SwiftUI's onAppear does NOT fire in this case because the
            // NSHostingView never left the hierarchy.  This notification
            // bridges the gap, forcing a full state + history reload.
            appearGeneration += 1
            forceHistoryLoad()
        }
    }

    /// Force history to load and reset input state on every window appearance.
    private func forceHistoryLoad() {
        localInputText = session.inputText
        if session.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayMode = .history
            session.isDictionaryMode = false
            session.dictionaryEntry = nil
        }
        updateDisplayMode()
        FloatingPanel.shared.updateHeight(panelHeightForMode(displayMode), animate: false)
    }

    /// Derive displayMode from current session state.
    private func updateDisplayMode() {
        if session.isTranslating {
            displayMode = .translation
        } else if session.isDictionaryMode || session.dictionaryEntry?.isWord == true {
            displayMode = .dictionary
        } else if session.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayMode = .history
        } else {
            displayMode = .translation
        }
    }

    // MARK: - Dynamic Height (panelSize == "dynamic")

    /// Computes the exact pixel height of `text` using `NSString.boundingRect`
    /// with the StreamingTextView font (system 15 pt, lineSpacing 4) and the
    /// available text width (364 pt).  This accurately accounts for visual line
    /// wrapping — no more `\n`-based guessing.
    private func computeTextPixelHeight(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .paragraphStyle: textParagraphStyle
        ]
        let size = NSSize(width: textAvailableWidth, height: .greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(
            with: size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(rect.height)
    }

    /// Recomputes the panel height using real text layout measurement.
    ///
    /// **Height model**: `dynamicMinH` (460 pt) already provides ~257 pt of free
    /// workspace area.  The panel only grows when the measured text pixel height
    /// (plus internal padding + 3‑line headroom) exceeds that slack.
    ///
    /// **Animation timing**: SwiftUI renders the updated text immediately
    /// (text-first), then this method fires `updateHeight(animate: true)` which
    /// runs an AppKit frame animation (frame-follows).  The +3‑line headroom
    /// gives the visual effect of the frame leading slightly ahead of content.
    private func updateDynamicHeight(for text: String, isStreaming: Bool) {
        guard panelSize == "dynamic", displayMode == .translation,
              !AppState.isUserDraggingWindow else { return }

        let textH = computeTextPixelHeight(text)
        guard textH != lastTextPixelHeight else { return }
        lastTextPixelHeight = textH

        /// Extra headroom: 3 additional lines so the frame expands ahead of content.
        let fontLineH = textFont.ascender + abs(textFont.descender) + textFont.leading + 4  // +4 lineSpacing
        let headroom3Lines: CGFloat = 3 * fontLineH

        let freeWorkspace = dynamicMinH - chromeHeight       // ≈ 257 pt
        let neededWorkspace = textH + textInternalVPad + headroom3Lines
        let overflow = max(0, neededWorkspace - freeWorkspace)
        let targetH = dynamicMinH + overflow
        let clamped = max(dynamicMinH, min(dynamicMaxH, targetH))

        dynamicPanelHeight = clamped
        FloatingPanel.shared.updateHeight(clamped, animate: true)
    }

    // MARK: - Drag bar (animation-isolated leaf)

    private var indicatorMode: IndicatorMode {
        if session.showErrorPulse       { return .red }
        if session.isTranslating        { return .yellow }
        if session.showSuccessPulse     { return .green }
        return .none
    }

    private var dragBar: some View {
        IsolatedIndicatorView(mode: indicatorMode)
            .id("dragIndicator")  // stable identity prevents animation resets
    }

    // MARK: - Header bar (V0.6: micro-typography, left controls, right picker + pin)

    private var headerBar: some View {
        HStack(spacing: AppTheme.spaceXS) {
            // App icon
            Image(nsImage: appIcon(size: 18)).resizable().frame(width: 18, height: 18)
            // Mode indicator — bumped to fontSizeFine
            Text(isDict ? "查词" : "翻译")
                .font(.system(size: AppTheme.fontSizeFine, weight: .semibold))
                .foregroundColor(AppTheme.textPrimary)
            contextBadge
            Spacer()
            // Provider picker menu — flush right
            providerMenu
            // Pin toggle
            pinButton
        }
        .padding(.horizontal, AppTheme.spaceSM).padding(.vertical, 6)
    }

    // MARK: Context Badge (bumped to fontSizeFine)

    private var contextBadge: some View {
        Button(action: {
            withAnimation(AppTheme.Motion.snip.gated) {
                AppState.shared.configuration.isContextAwareEnabled.toggle()
            }
        }) {
            HStack(spacing: 3) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: AppTheme.fontSizeFine, weight: .bold))
                Text(isContextAware ? "Context On" : "Context Off")
                    .font(.system(size: AppTheme.fontSizeMicro, weight: .bold))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(isContextAware ? AppTheme.accentAction.opacity(0.12) : Color.secondary.opacity(0.08))
            .foregroundColor(isContextAware ? AppTheme.accentAction : AppTheme.textSecondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Provider Picker Menu (bumped to fontSizeFine)

    private var providerMenu: some View {
        Group {
            if !state.enabledProviders.isEmpty {
                Menu {
                    ForEach(state.enabledProviders) { p in
                        Button(action: { switchProvider(to: p) }) {
                            HStack {
                                Circle().fill(currentProviderID == p.id ? AppTheme.accentAction : .clear).frame(width: 6, height: 6)
                                Text(p.name.isEmpty ? "未命名" : p.name)
                                if currentProviderID == p.id { Image(systemName: "checkmark").font(.caption).foregroundColor(AppTheme.accentAction) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu").font(.system(size: AppTheme.fontSizeFine))
                        Text(activeProvider?.name ?? "API")
                            .font(.system(size: AppTheme.fontSizeFine))
                            .lineLimit(1)
                            .frame(maxWidth: 70)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .foregroundColor(AppTheme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06)).cornerRadius(AppTheme.radiusXS)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 110)
            }
        }
    }

    private func switchProvider(to p: APIProvider) {
        if isDict { state.dictProviderID = p.id; ProviderStorageManager.saveDictProviderID(p.id) }
        else { state.selectedProviderID = p.id; ProviderStorageManager.saveSelectedProviderID(p.id) }
    }

    // MARK: Pin Button

    private var pinButton: some View {
        Button(action: {
            withAnimation(AppTheme.Motion.snip.gated) {
                isPinned.toggle()
                FloatingPanel.shared.isPinned = isPinned
            }
        }) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: AppTheme.fontSizeFine, weight: .medium))
                .foregroundColor(isPinned ? AppTheme.accentAction : AppTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(isPinned ? "取消固定窗口" : "固定窗口")
    }

    // MARK: - Permission

    private var permissionBlock: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 28)).foregroundColor(.orange)
            Text("需要辅助功能权限").font(.headline)
            Text("请前往 系统设置 → 隐私与安全性 → 辅助功能，添加并启用「OmniTrans」")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }.buttonStyle(.borderedProminent).controlSize(.small).tint(AppTheme.accentAction)
        }
        .padding(.vertical, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content Stack (V0.6: Input Card + Workspace — seamless, no divider)

    private var contentStack: some View {
        VStack(spacing: AppTheme.spaceXS) {
            inputCard
            workspaceArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    // ──────────────────────────────────────────────
    // MARK: Input Card (V0.6: Dynamic Editable Card)
    // ──────────────────────────────────────────────

    /// Exact single-line height: fontSizeBody × 1.35 line-height multiplier.
    private var exactLineHeight: CGFloat {
        AppTheme.fontSizeBody * 1.35
    }

    /// Padding inside the card (vertical).
    private let cardVPadding: CGFloat = 6

    /// Min height: 3 lines + vertical padding.
    private var inputMinHeight: CGFloat { 3 * exactLineHeight }
    /// Max height: 5 lines + vertical padding.
    private var inputMaxHeight: CGFloat { 5 * exactLineHeight }

    private var inputCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: inputBinding)
                    .font(.system(size: AppTheme.fontSizeBody))
                    .scrollContentBackground(.hidden)
                    .frame(
                        minHeight: isDict ? exactLineHeight : inputMinHeight,
                        maxHeight: isDict ? exactLineHeight : inputMaxHeight
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .topLeading) { placeholderOverlay }

                // ── Clear button (bottom-right, snip fade-in) ──
                if !localInputText.isEmpty {
                    Button(action: clearInput) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .padding(.bottom, 2)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, cardVPadding)
        .background(AppTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radiusMD, style: .continuous)
                .stroke(AppTheme.cardBorder, lineWidth: 0.5)
        )
        .animation(AppTheme.Motion.snip.gated, value: displayMode)
        .animation(AppTheme.Motion.snip.gated, value: localInputText.isEmpty)
    }

    /// Placeholder — two-line hint, unified at `fontSizeFine` (one step below body).
    /// Leading padding offsets the block by ~1 character to avoid overlapping the
    /// TextEditor cursor / text insertion point.
    private var placeholderOverlay: some View {
        Group {
            if localInputText.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("输入内容按下 Enter 开始翻译")
                        .font(.system(size: AppTheme.fontSizeFine))
                        .foregroundColor(AppTheme.textCaptionGray)
                    Text("\u{2318} + \u{21A9}  或  \u{21E7} + \u{21A9}  可换行")
                        .font(.system(size: AppTheme.fontSizeFine))
                        .foregroundColor(AppTheme.textCaptionGray.opacity(0.7))
                }
                .padding(.top, 2)
                .padding(.leading, 6)
                .allowsHitTesting(false)
            }
        }
    }

    /// Shared binding for TextEditor with modifier-key-aware multi-line support.
    /// Naked Enter → translate.  Cmd+Enter / Shift+Enter → insert newline.
    private var inputBinding: Binding<String> {
        Binding(
            get: { localInputText },
            set: { newValue in
                // Check for trailing newline (Enter key press)
                if newValue.hasSuffix("\n") {
                    // Detect modifier-held Enter via current NSEvent
                    let flags = NSApp.currentEvent?.modifierFlags ?? []
                    let isModifierEnter = flags.contains(.command) || flags.contains(.shift)
                    if isModifierEnter {
                        // Allow multi-line — keep the newline
                        localInputText = newValue
                        session.inputText = newValue
                        return
                    }
                    // Naked Enter — strip newline and translate
                    let trimmed = newValue.trimmingCharacters(in: .newlines)
                    localInputText = trimmed
                    session.inputText = trimmed
                    if !trimmed.isEmpty { executeTranslation(trimmed) }
                    return
                }
                localInputText = newValue
                session.inputText = newValue
                if newValue.isEmpty {
                    displayMode = .history
                } else if session.isDictionaryMode || session.dictionaryEntry?.isWord == true {
                    displayMode = .dictionary
                } else if !session.translatedText.isEmpty || session.isTranslating {
                    displayMode = .translation
                } else {
                    // User is typing fresh text — no existing translation result.
                    // Stay in history mode until Enter is pressed.
                    displayMode = .history
                }
            }
        )
    }

    private func executeTranslation(_ text: String) {
        session.inputText = text
        state.translate()
    }

    private func clearInput() {
        // Clear translation state immediately (outside animation) so
        // subsequent typing cannot flash stale translatedText / dictionaryEntry.
        session.translatedText = ""
        session.dictionaryEntry = nil
        session.isDictionaryMode = false
        session.errorMessage = nil
        MemoryPurgeHelper.shared.purgeBackendCache()

        withAnimation(AppTheme.Motion.snip.gated) {
            localInputText = ""
            session.inputText = ""
            displayMode = .history
        }
        FloatingPanel.shared.updateHeight(panelHeightForMode(.history))
    }

    // ──────────────────────────────────────────────
    // MARK: Workspace Area (Mode-dependent)
    // ──────────────────────────────────────────────

    @ViewBuilder
    private var workspaceArea: some View {
        switch displayMode {
        case .history:
            historyWorkspace
        case .translation:
            translationWorkspace
        case .dictionary:
            dictionaryWorkspace
        }
    }

    // ── History Workspace ──

    private var historyWorkspace: some View {
        VStack(spacing: AppTheme.spaceXS) {
            // Search bar + clear button row — always visible
            HStack(spacing: 8) {
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

                Button(action: {
                    state.clearHistory()
                    historySearchText = ""
                    expandedHistoryItemId = nil
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 10))
                        Text("清除历史").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(AppTheme.error)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AppTheme.error.opacity(0.08))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            // History list — forced re-evaluation via .id
            let items = filteredHistoryItems
            if historyDisabled {
                Text("历史记录已关闭")
                    .font(.system(size: AppTheme.fontSizeFine))
                    .foregroundColor(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if items.isEmpty && !state.translationHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title).foregroundColor(.secondary)
                    Text("无匹配记录")
                        .font(.system(size: AppTheme.fontSizeFine))
                        .foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if state.translationHistory.isEmpty {
                if isHistoryLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(AppTheme.accentAction)
                        Text("正在加载历史记录…")
                            .font(.system(size: AppTheme.fontSizeFine))
                            .foregroundColor(AppTheme.textCaptionGray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "clock").font(.title).foregroundColor(.secondary)
                        Text("暂无翻译记录")
                            .font(.system(size: AppTheme.fontSizeFine))
                            .foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(items) { item in
                            historyCard(item)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .id("historyWorkspace")
    }

    // ── Translation Workspace ──

    private var translationWorkspace: some View {
        VStack(spacing: AppTheme.spaceXS) {
            if session.isTranslating || !session.translatedText.isEmpty || session.errorMessage != nil {
                VStack(spacing: 0) {
                    StreamingTextView().environment(session)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(AppTheme.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMD, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.radiusMD, style: .continuous)
                        .stroke(AppTheme.cardBorder, lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 2)

                if let err = session.errorMessage, !session.isTranslating {
                    translationErrorBlock(err)
                }
            }
        }
    }

    private func translationErrorBlock(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(msg).font(.caption).foregroundColor(.red).lineLimit(4)
            Button(action: { state.retryTranslate() }) {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.system(size: AppTheme.fontSizeFine))
            }.buttonStyle(.borderedProminent).controlSize(.small).tint(AppTheme.accentAction).disabled(session.isTranslating)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // ── Dictionary Workspace ──

    private var dictionaryWorkspace: some View {
        Group {
            if session.isTranslating {
                VStack(spacing: 14) {
                    SkeletonShimmerView(compact: true).padding(.horizontal, 60)
                    Text("正在查询词典…").font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 24)
            } else if let entry = session.dictionaryEntry, entry.isWord {
                ScrollView {
                    Group {
                        if isNativeDict {
                            NativeDictionaryView(entry: entry)
                        } else {
                            DictionaryCardView(entry: entry)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = session.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(4)
                    Button(action: { state.retryTranslate() }) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: AppTheme.fontSizeFine))
                    }.buttonStyle(.borderedProminent).controlSize(.small).tint(AppTheme.accentAction).disabled(session.isTranslating)
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: History Card (Expandable)
    // ──────────────────────────────────────────────

    @ViewBuilder
    private func historyCard(_ item: HistoryEntry) -> some View {
        let isExpanded = expandedHistoryItemId == item.id

        VStack(alignment: .leading, spacing: 8) {
            // ── Card header ──
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
                .font(.system(size: AppTheme.fontSizeFine))
                .lineLimit(isExpanded ? nil : 1)
                .foregroundColor(AppTheme.textPrimary)

            if !isExpanded {
                Text(item.output)
                    .font(.system(size: AppTheme.fontSizeFine))
                    .lineLimit(1)
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
                if isExpanded { expandedHistoryItemId = nil }
                else { expandedHistoryItemId = item.id }
            }
        }
    }

    // MARK: - Compact Dictionary Block (for history cards)

    @ViewBuilder
    private func compactDictionaryBlock(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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

    // MARK: - Bottom bar (V0.6: micro typography)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            langMenu; Spacer()
            if !session.translatedText.isEmpty, !session.isTranslating, !isDict {
                Text("\(session.translatedText.count) 字符")
                    .font(.system(size: AppTheme.fontSizeFine))
                    .foregroundColor(AppTheme.textSecondary)
            }
            actionButtons
        }
        .padding(.horizontal, AppTheme.spaceSM).padding(.vertical, 4)
    }

    private var langMenu: some View {
        Menu {
            ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Button(l.rawValue) { state.targetLang = l } }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "globe").font(.system(size: AppTheme.fontSizeFine))
                Text(state.targetLang.rawValue)
                    .font(.system(size: AppTheme.fontSizeFine))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06)).cornerRadius(AppTheme.radiusXS)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !session.translatedText.isEmpty || session.dictionaryEntry != nil {
            Button(action: copyResult) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: AppTheme.fontSizeFine))
            }.buttonStyle(.borderless)
            Button(action: speakResult) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: AppTheme.fontSizeFine))
            }.buttonStyle(.borderless)
                .disabled(session.translatedText.isEmpty && session.dictionaryEntry == nil)
        }
        Button(isDict ? "重新查词" : "翻译") { state.translate() }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .tint(AppTheme.accentAction)
            .disabled(session.isTranslating || localInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var resizeGrip: some View {
        HStack {
            Spacer()
            Image(systemName: "arrowtriangle.down.forward.and.arrowtriangle.up.backward")
                .font(.system(size: 8)).foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 4).padding(.bottom, 4)
    }

    // MARK: - Actions

    private func speakResult() {
        let text: String = isDict ? (session.dictionaryEntry?.word ?? "") : session.translatedText
        guard !text.isEmpty else { return }
        TTSManager.shared.speakNative(text: text)
    }
    private func copyResult() {
        ClipboardMonitor.shared.suppressNext = true; NSPasteboard.general.clearContents()
        if let entry = session.dictionaryEntry, entry.isWord {
            let parts = [entry.word] + (entry.phonetic.isEmpty ? [] : [entry.phonetic])
                + entry.definitions.map { "[\($0.pos)] \($0.meaning)" }
                + entry.examples.flatMap { ["• \($0.en)", "  \($0.zh)"] }
            NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
        } else { NSPasteboard.general.setString(session.translatedText, forType: .string) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: - Restore History

    private func restoreHistory(_ item: HistoryEntry) {
        localInputText = item.input
        state.inputText = item.input
        state.translatedText = item.output
        state.sourceLang = item.sourceLang
        state.targetLang = item.targetLang
        state.errorMessage = nil
        if item.isDictionaryMode {
            state.isDictionaryMode = true
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
        if let p = state.providers.first(where: { $0.name == item.providerName }) {
            state.selectedProviderID = p.id
            ProviderStorageManager.saveSelectedProviderID(p.id)
        }
        displayMode = .translation
    }

    // MARK: - Relative Time

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
}
