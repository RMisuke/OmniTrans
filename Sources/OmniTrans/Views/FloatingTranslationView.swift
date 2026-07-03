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

// MARK: - Indicator Colors

private let greenPulse  = Color(red: 0.204, green: 0.831, blue: 0.600)  // #34d399
private let redPulse    = Color(red: 1.000, green: 0.361, blue: 0.376)  // #ff5c60
private let yellowPulse = Color(red: 0.980, green: 0.784, blue: 0.000)  // #fac800

// MARK: - Floating Translation View

struct FloatingTranslationView: View {
    @ObservedObject var state: AppState
    @AppStorage("panel_size") private var panelSize = "default"
    @AppStorage("animations_enabled") private var animationsEnabled = true

    // ── Derived ──
    private var isDict: Bool { state.isDictionaryMode || state.dictionaryEntry?.isWord == true }
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

    private var transitionAnim: Animation? {
        animationsEnabled ? .easeInOut(duration: 0.55) : nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            dragBar
            headerBar
            if state.showPermissionHint { permissionBlock }
            else { contentArea }
            bottomBar
            resizeGrip
        }
        .frame(minWidth: 340, minHeight: minH)
        .background(AdaptiveGlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animationsGated()
        .onKeyPress(.escape) { FloatingPanel.shared.hide(); return .handled }
        .onChange(of: state.inputText) { _, v in state.detectedIsWord = WordDetector.isWord(v) }
    }

    // MARK: - Drag bar (top) — three-color indicator, smooth transitions

    private enum IndicatorMode { case none, yellow, green, red }

    private var indicatorMode: IndicatorMode {
        if state.showErrorPulse       { return .red }
        if state.isTranslating        { return .yellow }
        if state.showSuccessPulse     { return .green }
        return .none
    }

    private var indicatorColor: Color {
        switch indicatorMode {
        case .yellow: return yellowPulse
        case .green:  return greenPulse
        case .red:    return redPulse
        case .none:   return .clear
        }
    }

    /// Current display opacity — animated smoothly across state transitions.
    @State private var displayOpacity: Double = 0.0
    @State private var breathPhase: Double = 0.0
    @State private var activeMode: IndicatorMode = .none

    /// Fixed height for the drag bar region to prevent layout jumps
    /// from blur-extended glow layers. Clips overflow.
    private let dragBarHeight: CGFloat = 20

    private var dragBar: some View {
        HStack {
            Spacer()
            ZStack {
                // Base dim capsule — always visible
                Capsule().fill(.quaternary).frame(width: 36, height: 5)

                // Colored glow layers — always rendered, opacity driven
                // Inner glow
                Capsule().fill(indicatorColor)
                    .frame(width: 36, height: 5)
                    .blur(radius: 4)
                    .opacity(displayOpacity * 0.9)
                // Outer halo
                Capsule().fill(indicatorColor.opacity(0.45))
                    .frame(width: 44, height: 8)
                    .blur(radius: 10)
                    .opacity(displayOpacity * 0.85)
            }
            .frame(width: 50, height: dragBarHeight)  // fixed region, clips glow
            .clipped()
            .shadow(color: displayOpacity > 0.01 ? indicatorColor.opacity(0.25 * displayOpacity) : .clear,
                    radius: 6, y: 0)
            Spacer()
        }
        .frame(height: dragBarHeight)
        .padding(.top, 2)
        .onChange(of: indicatorMode) { _, newMode in transition(to: newMode) }
        .onAppear { activeMode = indicatorMode; displayOpacity = indicatorMode == .none ? 0 : breathOpacity() }
    }

    // ── Smooth state transitions ──

    private func transition(to newMode: IndicatorMode) {
        let old = activeMode
        activeMode = newMode

        if newMode == .none {
            // Fade out smoothly
            withAnimation(transitionAnim) { displayOpacity = 0 }
            stopBreathing()
        } else if old == .none {
            // Fade in smoothly
            withAnimation(transitionAnim) { displayOpacity = breathOpacity() }
            if newMode == .yellow { startBreathing() }
        } else if old == .yellow && newMode != .yellow {
            // Yellow → green/red: stop breathing, crossfade
            stopBreathing()
            withAnimation(transitionAnim) { displayOpacity = 1.0 }
        } else if old != .yellow && newMode == .yellow {
            // Green/red → yellow: start breathing
            withAnimation(transitionAnim) { displayOpacity = breathOpacity() }
            startBreathing()
        } else {
            // Green ↔ red crossfade
            withAnimation(transitionAnim) { displayOpacity = 1.0 }
        }
    }

    private func breathOpacity() -> Double {
        0.5 + 0.5 * breathPhase
    }

    private func startBreathing() {
        guard animationsEnabled else { return }
        breathPhase = 0
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            breathPhase = 1.0
        }
    }

    private func stopBreathing() {
        breathPhase = 0
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(nsImage: appIcon(size: 18))
                .resizable().frame(width: 18, height: 18)
            Text(isDict ? "查词" : "翻译").font(.subheadline).bold()
            Spacer()
            providerMenu
            Text("\(state.sourceLang == .auto ? "自动" : state.sourceLang.rawValue) → \(state.targetLang.rawValue)")
                .font(.caption2).foregroundColor(.secondary)
            Button(action: { FloatingPanel.shared.hide() }) {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var providerMenu: some View {
        Group {
            if !state.enabledProviders.isEmpty {
                Menu {
                    ForEach(state.enabledProviders) { p in
                        Button(action: { switchProvider(to: p) }) {
                            HStack {
                                Circle()
                                    .fill(currentProviderID == p.id ? Color.accentColor : .clear)
                                    .frame(width: 6, height: 6)
                                Text(p.name.isEmpty ? "未命名" : p.name)
                                if currentProviderID == p.id {
                                    Image(systemName: "checkmark").font(.caption).foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu").font(.system(size: 9))
                        Text(activeProvider?.name ?? "API").font(.caption2).lineLimit(1).frame(maxWidth: 70)
                        Image(systemName: "chevron.down").font(.system(size: 7))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06)).cornerRadius(4)
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
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.vertical, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if isDict {
            dictContent
        } else {
            VStack(spacing: 0) {
                if !state.inputText.isEmpty { sourceBlock }
                translationContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // ── Source text ──

    private var sourceBlock: some View {
        VStack(spacing: 0) {
            if state.detectedIsWord {
                wordBadge
            }
            ScrollView {
                Text(state.inputText)
                    .font(.system(size: 16)).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 52, maxHeight: 80)
            .background(.ultraThinMaterial).cornerRadius(8).padding(.horizontal, 10)
        }
    }

    private var wordBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "character.book.closed.fill").font(.caption2).foregroundColor(.accentColor)
            Text("检测到单词 — 词典模式").font(.system(size: 10)).foregroundColor(.accentColor)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.08)).cornerRadius(4)
        .padding(.horizontal, 14).padding(.bottom, 4)
    }

    // ── Translation result ──

    @ViewBuilder
    private var translationContent: some View {
        if state.isTranslating && state.translatedText.isEmpty {
            VStack(spacing: 14) {
                SkeletonShimmerView()
                Text("正在翻译…").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
        } else if !state.translatedText.isEmpty || state.isTranslating {
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    Text(state.translatedText)
                        .font(.system(size: 15)).textSelection(.enabled).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .drawingGroup()
                    if state.isTranslating {
                        Rectangle().fill(Color.accentColor).frame(width: 2, height: 15)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let err = state.errorMessage {
            errorBlock(err)
        }
    }

    // ── Dictionary content ──

    @ViewBuilder
    private var dictContent: some View {
        if state.isTranslating {
            dictLoadingBlock
        } else if let entry = state.dictionaryEntry, entry.isWord {
            ScrollView {
                Group {
                    if isNativeDict {
                        NativeDictionaryView(entry: entry)
                    } else {
                        DictionaryCardView(entry: entry)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let err = state.errorMessage {
            errorBlock(err)
        }
    }

    private var dictLoadingBlock: some View {
        VStack(spacing: 14) {
            SkeletonShimmerView(compact: true).padding(.horizontal, 60)
            Text("正在查询词典…").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
    }

    // ── Error ──

    private func errorBlock(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(msg).font(.caption).foregroundColor(.red).lineLimit(4)
            Button(action: { state.retryTranslate() }) {
                Label("重试", systemImage: "arrow.clockwise").font(.caption2)
            }.buttonStyle(.borderedProminent).controlSize(.small).disabled(state.isTranslating)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            langMenu
            Spacer()
            if !state.translatedText.isEmpty, !state.isTranslating, !isDict {
                Text("\(state.translatedText.count) 字符").font(.caption2).foregroundColor(.secondary)
            }
            actionButtons
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var langMenu: some View {
        Menu {
            ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in
                Button(l.rawValue) { state.targetLang = l }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 11))
                Text(state.targetLang.rawValue).font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06)).cornerRadius(5)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !state.translatedText.isEmpty || state.dictionaryEntry != nil {
            Button(action: copyResult) {
                Image(systemName: "doc.on.doc").font(.caption)
            }.buttonStyle(.borderless)
            Button(action: speakResult) {
                Image(systemName: "speaker.wave.2").font(.caption)
            }.buttonStyle(.borderless)
                .disabled(state.translatedText.isEmpty && state.dictionaryEntry == nil)
        }
        Button(isDict ? "重新查词" : "翻译") { state.translate() }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(state.isTranslating || state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Resize grip (bottom)

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
        let text: String
        if isDict, let entry = state.dictionaryEntry { text = entry.word }
        else { text = state.translatedText }
        guard !text.isEmpty else { return }
        TTSManager.shared.speakNative(text: text)
    }

    private func copyResult() {
        ClipboardMonitor.shared.suppressNext = true
        NSPasteboard.general.clearContents()
        if let entry = state.dictionaryEntry, entry.isWord {
            let parts: [String] = [entry.word]
                + (entry.phonetic.isEmpty ? [] : [entry.phonetic])
                + entry.definitions.map { "[\($0.pos)] \($0.meaning)" }
                + entry.examples.flatMap { ["• \($0.en)", "  \($0.zh)"] }
            NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
        } else {
            NSPasteboard.general.setString(state.translatedText, forType: .string)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
