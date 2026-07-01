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

    // MARK: - Toast

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

    // MARK: - Provider menu

    private var providerMenu: some View {
        Menu {
            if state.enabledProviders.isEmpty {
                Text("无可用 API").foregroundColor(.secondary)
                Divider()
                Button("添加 API 配置...") { showSettings = true }
            } else {
                Section("选择 API") {
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)
            .help("交换语言")

            Picker("目标语言", selection: $state.targetLang) {
                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Text(l.rawValue).tag(l) }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Spacer()

            // ── Clear button ──
            if !state.inputText.isEmpty {
                Button(action: clearAll) {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle").font(.caption)
                        Text("清空").font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help("清空输入和翻译结果")
            }

            // ── Translate button ──
            Button(action: { state.translate() }) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                    Text("翻译").font(.system(size: 11))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(state.isTranslating || state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    // MARK: - Input

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("输入文本").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(state.inputText.count) 字符").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 6)

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
                .padding(.horizontal, 12).padding(.top, 4)
            }

            TextEditor(text: $state.inputText)
                .font(.system(size: 15))
                .frame(minHeight: 72, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Output

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("翻译结果").font(.caption).foregroundColor(.secondary)
                Spacer()
                if !state.translatedText.isEmpty {
                    Text("\(state.translatedText.count) 字符").font(.caption2).foregroundColor(.secondary)
                }
                if !state.translatedText.isEmpty {
                    Button(action: copyResult) {
                        Image(systemName: "doc.on.doc").font(.caption2)
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
                    .padding(.leading, 16).padding(.top, 10)
                }
                if let error = state.errorMessage {
                    errorBlock(error)
                }
                HStack(alignment: .top, spacing: 0) {
                    Text(state.translatedText)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if state.isTranslating && showCursor {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: 15)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 4)
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Error

    private func errorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error).font(.caption).foregroundColor(.red)
            Button(action: { state.retryTranslate() }) {
                Label("重试", systemImage: "arrow.clockwise").font(.caption2)
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(state.isTranslating)
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .cornerRadius(8)
        .padding(.horizontal, 12).padding(.top, 6)
    }

    // MARK: - Actions

    private func swapLanguages() {
        guard state.sourceLang != .auto else { return }
        let tmp = state.sourceLang
        state.sourceLang = state.targetLang
        state.targetLang = tmp
    }

    private func clearAll() {
        state.inputText = ""
        state.translatedText = ""
        state.dictionaryEntry = nil
        state.errorMessage = nil
    }

    private func copyResult() {
        ClipboardMonitor.shared.suppressNext = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.translatedText, forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        showCopyToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopyToast = false }
    }

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
