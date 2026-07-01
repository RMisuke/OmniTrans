import SwiftUI

struct FloatingTranslationView: View {
    @ObservedObject var state: AppState
    @State private var showCursor = true
    @State private var cursorTimer: Timer?
    @State private var dictProgress: Double = 0

    private var dismissMode: String {
        UserDefaults.standard.string(forKey: "dismiss_mode") ?? "clickOutside"
    }
    private var isDict: Bool { state.isDictionaryMode || state.dictionaryEntry?.isWord == true }
    private var dictProviderName: String {
        guard isDict, let id = state.dictProviderID,
              let p = state.enabledProviders.first(where: { $0.id == id })
        else { return state.selectedProvider?.name ?? "" }
        return p.name
    }
    private var isNativeDict: Bool {
        guard let id = state.dictProviderID else { return true }
        return state.enabledProviders.first(where: { $0.id == id })?.kind == .macOSNative
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            headerView
            if state.showPermissionHint {
                permissionView
            } else {
                contentBody
            }
            bottomBar
            resizeGrip
        }
        .frame(minWidth: 340, minHeight: 380)
        .background(.regularMaterial)
        .cornerRadius(12)
        .onKeyPress(.escape) { FloatingPanel.shared.hide(); return .handled }
        .onChange(of: state.isTranslating) { _, t in t ? startAnimating() : stopAnimating() }
        .onChange(of: state.inputText) { _, v in state.detectedIsWord = WordDetector.isWord(v) }
        .onChange(of: state.streamingFinished) { _, _ in stopCursor() }
        .overlay {
            if state.showSuccessPulse {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.green, lineWidth: 2)
            }
        }
    }

    // MARK: - Drag handle

    private var dragHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(.quaternary)
                .frame(width: 36, height: 5)
            Spacer()
        }
        .padding(.top, 6).padding(.bottom, 2)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 6) {
            Image(systemName: isDict ? "character.book.closed.fill" : "character.bubble.fill")
                .foregroundColor(.accentColor).font(.caption)
            Text(isDict ? "查词" : "翻译")
                .font(.subheadline).bold()

            Spacer()

            // ── API switcher in floating panel ──
            if !state.enabledProviders.isEmpty {
                Menu {
                    ForEach(state.enabledProviders) { p in
                        Button(action: {
                            state.selectedProviderID = p.id
                            ProviderStorageManager.saveSelectedProviderID(p.id)
                        }) {
                            HStack {
                                Circle()
                                    .fill(p.id == state.selectedProviderID ? Color.accentColor : Color.clear)
                                    .frame(width: 6, height: 6)
                                Text(p.name.isEmpty ? "未命名" : p.name)
                                if p.id == state.selectedProviderID {
                                    Image(systemName: "checkmark")
                                        .font(.caption).foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu").font(.system(size: 9))
                        Text(state.selectedProvider?.name ?? "API")
                            .font(.caption2).lineLimit(1)
                            .frame(maxWidth: 70)
                        Image(systemName: "chevron.down").font(.system(size: 7))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 110)
            }

            Text("\(state.sourceLang == .auto ? "自动" : state.sourceLang.rawValue) → \(state.targetLang.rawValue)")
                .font(.caption2).foregroundColor(.secondary)

            Button(action: { FloatingPanel.shared.hide() }) {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(dismissMode == "clickOutside" ? "Esc / 点击外部关闭" : "Esc 关闭")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Permission

    private var permissionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 28)).foregroundColor(.orange)
            Text("需要辅助功能权限").font(.headline)
            Text("请前往 系统设置 → 隐私与安全性 → 辅助功能，添加并启用「OmniTrans」")
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }.buttonStyle(.borderedProminent).controlSize(.small)
        }.padding(.vertical, 24).frame(maxWidth: .infinity)
    }

    // MARK: - Content body

    @ViewBuilder
    private var contentBody: some View {
        if isDict {
            dictOnlyBody
        } else {
            VStack(spacing: 0) {
                if !state.inputText.isEmpty { sourceBlock }
                resultBlock
            }
        }
    }

    @ViewBuilder
    private var dictOnlyBody: some View {
        if state.isTranslating {
            dictProgressView
        } else if let entry = state.dictionaryEntry, entry.isWord {
            dictResultView(entry)
        } else if let err = state.errorMessage {
            errorView(err)
        } else {
            Spacer(minLength: 60)
        }
    }

    private var sourceBlock: some View {
        VStack(spacing: 0) {
            if state.detectedIsWord {
                HStack(spacing: 4) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.caption2).foregroundColor(.accentColor)
                    Text("检测到单词 — 词典模式")
                        .font(.system(size: 10)).foregroundColor(.accentColor)
                }
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(4)
                .padding(.horizontal, 14).padding(.bottom, 4)
            }
            ScrollView {
                Text(state.inputText)
                    .font(.system(size: 16)).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 52, maxHeight: 80)
            .background(.ultraThinMaterial)
            .cornerRadius(8).padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private var resultBlock: some View {
        if state.isTranslating {
            streamingTextView
        } else if !state.translatedText.isEmpty {
            translatedTextView
        } else if let err = state.errorMessage {
            errorView(err)
        } else {
            Spacer(minLength: 60)
        }
    }

    private func dictResultView(_ entry: DictionaryEntry) -> some View {
        ScrollView {
            if isNativeDict {
                NativeDictionaryView(entry: entry)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            } else {
                DictionaryCardView(entry: entry)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    private var dictProgressView: some View {
        VStack(spacing: 14) {
            ProgressView(value: dictProgress).progressViewStyle(.linear)
                .tint(.accentColor).padding(.horizontal, 50)
            Text("正在查询词典…")
                .font(.caption).foregroundColor(.secondary)
        }.padding(.vertical, 28)
    }

    private var streamingTextView: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                Text(state.translatedText)
                    .font(.system(size: 15)).textSelection(.enabled).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state.isTranslating && showCursor {
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 15)
                }
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var translatedTextView: some View {
        ScrollView {
            Text(state.translatedText)
                .font(.system(size: 15)).textSelection(.enabled).lineSpacing(4)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorView(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(err).font(.caption).foregroundColor(.red).lineLimit(4)
            Button(action: { state.retryTranslate() }) {
                Label("重试", systemImage: "arrow.clockwise").font(.caption2)
            }.buttonStyle(.borderedProminent).controlSize(.small).disabled(state.isTranslating)
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in
                    Button(l.rawValue) { state.targetLang = l }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 11))
                    Text(state.targetLang.rawValue).font(.caption2)
                }.padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06)).cornerRadius(5)
            }.buttonStyle(.plain)
            Spacer()
            if !state.translatedText.isEmpty && !state.isTranslating && !isDict {
                Text("\(state.translatedText.count) 字符").font(.caption2).foregroundColor(.secondary)
            }
            if !state.translatedText.isEmpty || state.dictionaryEntry != nil {
                Button(action: copyResult) {
                    Image(systemName: "doc.on.doc").font(.caption)
                }.buttonStyle(.borderless)
            }
            Button(isDict ? "重新查词" : "翻译") { state.translate() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(state.isTranslating || state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Resize grip

    private var resizeGrip: some View {
        HStack {
            Spacer()
            Image(systemName: "arrowtriangle.down.forward.and.arrowtriangle.up.backward")
                .font(.system(size: 8))
                .foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 4).padding(.bottom, 4)
    }

    // MARK: - Animations

    private func startAnimating() { if isDict { startDictProgress() } else { startCursor() } }
    private func stopAnimating() { stopCursor(); dictProgress = 0 }

    private func startCursor() {
        showCursor = true; cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { _ in showCursor.toggle() }
    }
    private func stopCursor() { cursorTimer?.invalidate(); cursorTimer = nil; showCursor = false }

    private func startDictProgress() {
        dictProgress = 0
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { t in
            guard state.isDictionaryMode else { t.invalidate(); return }
            dictProgress = min(dictProgress + 0.04, 0.9)
        }
    }

    private func copyResult() {
        ClipboardMonitor.shared.suppressNext = true
        NSPasteboard.general.clearContents()
        if let entry = state.dictionaryEntry, entry.isWord {
            let parts: [String] = [entry.word] + (entry.phonetic.isEmpty ? [] : [entry.phonetic])
                + entry.definitions.map { "[\($0.pos)] \($0.meaning)" }
                + entry.examples.flatMap { ["• \($0.en)", "  \($0.zh)"] }
            NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
        } else {
            NSPasteboard.general.setString(state.translatedText, forType: .string)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
