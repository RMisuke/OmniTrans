import SwiftUI

struct TranslationView: View {
    @ObservedObject var state: AppState
    @Binding var showSettings: Bool
    @State private var showCopyToast = false
    @State private var swapTrigger = false
    @State private var showCursor = true
    @State private var cursorTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            languageBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            inputArea
            Divider()
            outputArea
        }
        .overlay(alignment: .top) {
            if showCopyToast {
                copyToast
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showCopyToast)
        .onChange(of: state.isTranslating) { _, translating in
            if translating { startCursor() } else { stopCursor() }
        }
        .onChange(of: state.streamingFinished) { _, _ in stopCursor() }
    }

    private var copyToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text("已拷贝到剪贴板").font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(radius: 4)
        .padding(.top, 6)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "character.bubble")
                .foregroundColor(.accentColor)
            Text("OmniTrans").font(.headline)

            if state.isTranslating {
                ProgressView().scaleEffect(0.5).padding(.leading, 4)
            }
            // A3: Success check
            if state.showSuccessPulse {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .scaleEffect(state.showSuccessPulse ? 1.3 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: state.showSuccessPulse)
            }

            Spacer()
            providerMenu
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("API 配置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var providerMenu: some View {
        Menu {
            if state.enabledProviders.isEmpty {
                Text("无可用 API").foregroundColor(.secondary)
                Divider()
                Button("添加 API 配置...") { showSettings = true }
            } else {
                Section("选择 API") {
                    ForEach(state.enabledProviders) { p in
                        Button(action: { state.selectedProviderID = p.id }) {
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
                }
                Divider()
                Button("管理 API...") { showSettings = true }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(state.selectedProvider?.name ?? "选择 API")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(state.selectedProvider == nil ? Color.orange.opacity(0.15) : Color.primary.opacity(0.06))
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 180)
    }

    // MARK: - Language bar

    private var languageBar: some View {
        HStack(spacing: 6) {
            Picker("源语言", selection: $state.sourceLang) {
                ForEach(TranslationLanguage.allCases) { l in Text(l.rawValue).tag(l) }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    swapLanguages()
                    swapTrigger.toggle()
                }
            }) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(.accentColor)
                    .rotationEffect(.degrees(swapTrigger ? 180 : 0))
            }
            .buttonStyle(.borderless)
            .help("交换源语言和目标语言")

            Picker("目标语言", selection: $state.targetLang) {
                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in
                    Text(l.rawValue).tag(l)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Spacer()

            Button(action: { state.translate() }) {
                HStack(spacing: 4) {
                    if state.isTranslating {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.trianglehead.swap")
                    }
                    Text(state.isTranslating ? "翻译中" : "翻译")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(state.isTranslating || state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("开始翻译 (⌘↩)")
        }
    }

    // MARK: - Input (B1: distinguished bg)

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("输入文本")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if !state.inputText.isEmpty {
                    Text("\(state.inputText.count) 字符").font(.caption2).foregroundColor(.secondary)
                    Button("清空") { state.inputText = "" }
                        .font(.caption2).buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12).padding(.top, 6)

            ZStack(alignment: .topLeading) {
                if state.inputText.isEmpty {
                    Text("选中文本 → 快捷键 → 悬浮窗翻译  |  也可直接粘贴后点翻译")
                        .font(.body)
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                TextEditor(text: $state.inputText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Output (B1: distinguished bg, B2: char count)

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("翻译结果")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if !state.translatedText.isEmpty {
                    Text("\(state.translatedText.count) 字符")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if !state.translatedText.isEmpty {
                    Button(action: copyResult) {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.on.doc")
                            Text("拷贝")
                        }
                        .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("拷贝翻译结果")
                }
            }
            .padding(.horizontal, 12).padding(.top, 6)

            ScrollView {
                if state.isTranslating && state.translatedText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("正在调用 \(state.selectedProvider?.name ?? "API") 翻译...")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.leading, 16)
                    .padding(.top, 10)
                }

                if let error = state.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                // A3: error shake
                                .offset(x: state.showErrorShake ? 3 : 0)
                                .animation(state.showErrorShake ? .easeInOut(duration: 0.06).repeatCount(4, autoreverses: true) : .default, value: state.showErrorShake)
                            Text("翻译失败").font(.caption).bold().foregroundColor(.orange)
                        }
                        Text(error).font(.caption).foregroundColor(.red).lineLimit(3)
                        HStack(spacing: 8) {
                            Button(action: { state.retryTranslate() }) {
                                Label("重试", systemImage: "arrow.clockwise")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(state.isTranslating)
                        }
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.06))
                    .cornerRadius(8)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }

                // A1: Streaming text with cursor
                HStack(alignment: .top, spacing: 0) {
                    Text(state.translatedText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if state.isTranslating && showCursor {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: 16)
                            .opacity(showCursor ? 1 : 0)
                            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: showCursor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
            .padding(.bottom, 4)
        }
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Actions

    private func swapLanguages() {
        guard state.sourceLang != .auto else { return }
        let tmp = state.sourceLang
        state.sourceLang = state.targetLang
        state.targetLang = tmp
    }

    private func copyResult() {
        ClipboardMonitor.shared.suppressNext = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.translatedText, forType: .string)
        // D1: Haptic
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        showCopyToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopyToast = false
        }
    }

    // MARK: - Cursor

    private func startCursor() {
        showCursor = true
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { _ in
            showCursor.toggle()
        }
    }

    private func stopCursor() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        showCursor = false
    }
}
