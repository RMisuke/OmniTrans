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

// MARK: - Floating Translation View

/// Main floating panel — "Solid Top, Thick Bottom" macOS 26 native layout.
///
/// - **Solid Top**: `headerBar` uses opaque `.windowBackgroundColor` with
///   a crisp 0.5pt hairline divider — no background bleed.
/// - **Thick Bottom**: content area uses `.ultraThickMaterial` (macOS 26+)
///   or `.sidebar` Mica (macOS 14+) via `AdaptiveGlassBackground`.
struct FloatingTranslationView: View {
    @ObservedObject var state: AppState
    @Environment(TranslationSessionStore.self) private var session
    @AppStorage("panel_size") private var panelSize = "default"
    @AppStorage("is_context_aware") private var isContextAware = true

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
    private var minH: CGFloat {
        switch panelSize { case "small": 280; case "large": 520; default: 380 }
    }

    var body: some View {
        VStack(spacing: 0) {
            dragBar
            headerBar
                .background(AppTheme.bgSolid)
                .headerDivider()
            if session.showPermissionHint { permissionBlock }
            else { contentArea }
            bottomBar
            resizeGrip
        }
        .frame(minWidth: 340, minHeight: minH)
        .background(AppTheme.bgSolid)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
        .animationsGated()
        .onKeyPress(.escape) { FloatingPanel.shared.hide(); return .handled }
        .onChange(of: session.inputText) { _, v in session.detectedIsWord = WordDetector.isWord(v) }
    }

    // MARK: - Drag bar (animation-isolated leaf)

    /// 三色状态机派生值，传入 ``IsolatedIndicatorView`` 作为输入。
    private var indicatorMode: IndicatorMode {
        if session.showErrorPulse       { return .red }
        if session.isTranslating        { return .yellow }
        if session.showSuccessPulse     { return .green }
        return .none
    }

    /// 自包含的状态指示灯。呼吸动画的 `@State` 完全限定在
    /// ``IsolatedIndicatorView`` 内部，父视图零无效化开销。
    private var dragBar: some View {
        IsolatedIndicatorView(mode: indicatorMode)
    }

    // MARK: - Header bar (Solid Opaque)

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(nsImage: appIcon(size: 18)).resizable().frame(width: 18, height: 18)
            Text(isDict ? "查词" : "翻译").font(.subheadline).bold().foregroundColor(AppTheme.textPrimary)
            contextBadge
            Spacer()
            providerMenu
            Text("\(state.sourceLang == .auto ? "自动" : state.sourceLang.rawValue) → \(state.targetLang.rawValue)")
                .font(.caption2).foregroundColor(AppTheme.textSecondary)
            Button(action: { FloatingPanel.shared.hide() }) {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(AppTheme.textSecondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, AppTheme.spaceSM).padding(.vertical, 6)
    }

    private var contextBadge: some View {
        Button(action: {
            withAnimation(AppTheme.Motion.snip.gated) {
                AppState.shared.configuration.isContextAwareEnabled.toggle()
            }
        }) {
            HStack(spacing: 3) {
                Image(systemName: "brain.head.profile").font(.system(size: 9, weight: .bold))
                Text(isContextAware ? "Context On" : "Context Off")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(isContextAware ? AppTheme.accentAction.opacity(0.12) : Color.secondary.opacity(0.08))
            .foregroundColor(isContextAware ? AppTheme.accentAction : AppTheme.textSecondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

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
                        Image(systemName: "cpu").font(.system(size: 9))
                        Text(activeProvider?.name ?? "API").font(.caption2).lineLimit(1).frame(maxWidth: 70)
                        Image(systemName: "chevron.down").font(.system(size: 7))
                    }
                    .foregroundColor(AppTheme.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06)).cornerRadius(AppTheme.radiusXS)
                }
                .menuStyle(.borderlessButton).frame(width: 110)
            }
        }
    }
    private var currentProviderID: UUID? { isDict ? state.dictProviderID : state.selectedProviderID }
    private func switchProvider(to p: APIProvider) {
        if isDict { state.dictProviderID = p.id; ProviderStorageManager.saveDictProviderID(p.id) }
        else { state.selectedProviderID = p.id; ProviderStorageManager.saveSelectedProviderID(p.id) }
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

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        VStack(spacing: AppTheme.spaceXS) {
            if isDict {
                // Dictionary mode: hide source block, let card fill full height
                FloatingDictionaryBlock(isNativeDict: isNativeDict, onRetry: { state.retryTranslate() }).environment(session)
            } else {
                if !session.inputText.isEmpty {
                    FloatingSourceBlock().environment(session)
                }
                StreamingTextView().environment(session)
                if let err = session.errorMessage, !session.isTranslating { translationErrorBlock(err) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func translationErrorBlock(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(msg).font(.caption).foregroundColor(.red).lineLimit(4)
            Button(action: { state.retryTranslate() }) {
                Label("重试", systemImage: "arrow.clockwise").font(.caption2)
            }.buttonStyle(.borderedProminent).controlSize(.small).tint(AppTheme.accentAction).disabled(session.isTranslating)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            langMenu; Spacer()
            if !session.translatedText.isEmpty, !session.isTranslating, !isDict {
                Text("\(session.translatedText.count) 字符").font(.caption2).foregroundColor(AppTheme.textSecondary)
            }
            actionButtons
        }
        .padding(.horizontal, AppTheme.spaceSM).padding(.vertical, 6)
    }

    private var langMenu: some View {
        Menu {
            ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Button(l.rawValue) { state.targetLang = l } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 11))
                Text(state.targetLang.rawValue).font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06)).cornerRadius(AppTheme.radiusXS)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !session.translatedText.isEmpty || session.dictionaryEntry != nil {
            Button(action: copyResult) { Image(systemName: "doc.on.doc").font(.caption) }.buttonStyle(.borderless)
            Button(action: speakResult) { Image(systemName: "speaker.wave.2").font(.caption) }.buttonStyle(.borderless)
                .disabled(session.translatedText.isEmpty && session.dictionaryEntry == nil)
        }
        Button(isDict ? "重新查词" : "翻译") { state.translate() }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .tint(AppTheme.accentAction)
            .disabled(session.isTranslating || session.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}
