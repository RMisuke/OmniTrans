import SwiftUI

struct TranslationView: View {
    @ObservedObject var state: AppState
    @Binding var showSettings: Bool
    @AppStorage("animations_enabled") private var animationsEnabled = true
    @State private var showCopyToast = false
    @State private var swapTrigger = false
    @State private var showCursor = true
    @State private var cursorTimer: Timer?

    private let fadeAnim: Animation? = .easeInOut(duration: 0.55)

    /// Lazy-loaded app icon, resized for header use.
    private var headerIcon: NSImage {
        if let path = Bundle.main.path(forResource: "icon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            let resized = NSImage(size: NSSize(width: 20, height: 20))
            resized.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20),
                      from: .zero, operation: .copy, fraction: 1.0)
            resized.unlockFocus()
            return resized
        }
        return NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: nil)!
    }

    /// Smooth animated indicator: red error / yellow loading / green success.
    @ViewBuilder
    private var headerIndicator: some View {
        if state.showErrorPulse {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(Color(red: 1.000, green: 0.361, blue: 0.376))
                .transition(.opacity)
        } else if state.isTranslating {
            Image(systemName: "circle.fill")
                .foregroundColor(Color(red: 0.980, green: 0.784, blue: 0.000))
                .scaleEffect(0.65)
                .transition(.opacity)
        } else if state.showSuccessPulse {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(red: 0.204, green: 0.831, blue: 0.600))
                .transition(.opacity)
        }
    }

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
        .animationsGated()
        .animation(fadeAnim, value: state.showErrorPulse)
        .animation(fadeAnim, value: state.isTranslating)
        .animation(fadeAnim, value: state.showSuccessPulse)
        .onChange(of: state.isTranslating) { _, translating in
            if translating {
                startCursor()
                // Clear NSTextView undo stack to prevent unbounded memory growth
                // from long-lived text editing history.
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.undoManager?.removeAllActions()
                }
            } else {
                stopCursor()
            }
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
        .background(AdaptiveGlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 4)
        .padding(.top, 6)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(nsImage: headerIcon)
                .resizable().frame(width: 20, height: 20)
            Text("OmniTrans").font(.headline)

            if state.isTranslating {
                ProgressView().scaleEffect(0.5).padding(.leading, 4)
            }
            headerIndicator

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
                withAnimationGated(.spring(response: 0.3, dampingFraction: 0.6)) {
                    swapTrigger.toggle()
                }
                swapLanguages()
            }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.accentColor)
                    .rotationEffect(.degrees(swapTrigger ? 180 : 0))
            }
            .buttonStyle(.borderless)
            .disabled(state.sourceLang == .auto)
            .help(state.sourceLang == .auto ? "自动检测语言时无法交换" : "交换语言方向")

            Picker("目标语言", selection: $state.targetLang) {
                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Text(l.rawValue).tag(l) }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Spacer()

            if !state.inputText.isEmpty {
                Button(action: clearAll) {
                    Image(systemName: "xmark.circle").font(.caption)
                }
                .buttonStyle(.borderless).help("清空")

                Button(action: { state.translate() }) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22)).foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(state.isTranslating)
                .help("翻译 (⌘⏎)")
            }
        }
    }

    // MARK: - Input

    private var inputArea: some View {
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
                .padding(.horizontal, 12).padding(.top, 4)
            }

            TextEditor(text: $state.inputText)
                .font(.system(size: 15))
                .frame(minHeight: 72, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12).padding(.vertical, 8)
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
                    Button(action: {
                        let textToSpeak = state.translatedText
                        guard !textToSpeak.isEmpty else { return }
                        TTSManager.shared.speakNative(text: textToSpeak)
                    }) {
                        Image(systemName: "speaker.wave.2").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("朗读翻译结果")
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
                    SkeletonShimmerView()
                        .padding(.horizontal, 4).padding(.top, 8)
                }
                if let error = state.errorMessage {
                    errorBlock(error)
                }
                HStack(alignment: .top, spacing: 0) {
                    Text(state.translatedText)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .identity
                        ))
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
            self.showCursor.toggle()
        }
    }

    private func stopCursor() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        showCursor = false
    }
}
