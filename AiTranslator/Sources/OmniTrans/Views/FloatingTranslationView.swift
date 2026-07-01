import SwiftUI

struct FloatingTranslationView: View {
    @ObservedObject var state: AppState
    @State private var showCursor = true
    @State private var cursorTimer: Timer?

    private var dismissMode: String {
        UserDefaults.standard.string(forKey: "dismiss_mode") ?? "clickOutside"
    }

    var body: some View {
        VStack(spacing: 0) {
            // C1: Drag handle
            dragHandle
            header
            if state.showPermissionHint {
                permissionHint
            } else if !state.inputText.isEmpty {
                sourceText
            }
            resultArea
            bottomBar
            // C2: Resize grip
            resizeGrip
        }
        .frame(minWidth: 340, minHeight: 200)
        .background(.regularMaterial)
        .cornerRadius(12)
        .onKeyPress(.escape) { FloatingPanel.shared.hide(); return .handled }
        .onChange(of: state.isTranslating) { _, translating in
            if translating { startCursor() } else { stopCursor() }
        }
        .onChange(of: state.streamingFinished) { _, _ in stopCursor() }
        // A3: Success pulse
        .overlay {
            if state.showSuccessPulse {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.green, lineWidth: 2)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Drag handle (C1)

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

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble.fill").foregroundColor(.accentColor).font(.caption)
            Text("翻译").font(.subheadline).bold()
            Spacer()
            if let p = state.selectedProvider {
                Text(p.name).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Text("\(state.sourceLang == .auto ? "自动" : state.sourceLang.rawValue) → \(state.targetLang.rawValue)")
                .font(.caption2).foregroundColor(.secondary)
            Button(action: { FloatingPanel.shared.hide() }) {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(dismissMode == "clickOutside" ? "Esc / 点击外部关闭" : "Esc 关闭")
            // A3: Error shake
            .offset(x: state.showErrorShake ? 3 : 0)
            .animation(state.showErrorShake ? .easeInOut(duration: 0.06).repeatCount(4, autoreverses: true) : .default, value: state.showErrorShake)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Permission hint

    private var permissionHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text("需要辅助功能权限")
                .font(.callout).bold()
            Text("请前往 系统设置 → 隐私与安全性 → 辅助功能，添加并启用「OmniTrans」")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Source text

    private var sourceText: some View {
        ScrollView {
            Text(state.inputText)
                .font(.caption).foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
        }
        .frame(maxHeight: 50)
        .background(Color.primary.opacity(0.03))  // B1: subtle bg for source
    }

    // MARK: - Result area

    private var resultArea: some View {
        ScrollView {
            if state.isTranslating && state.translatedText.isEmpty {
                HStack { ProgressView().scaleEffect(0.6); Text("翻译中...").font(.caption).foregroundColor(.secondary) }
                    .padding(.horizontal, 12).padding(.top, 8)
            }
            if let err = state.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(3)
                    Button(action: { state.retryTranslate() }) {
                        Label("重试", systemImage: "arrow.clockwise").font(.caption2)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(state.isTranslating)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
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
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))  // B1: subtle bg for result
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in
                    Button(l.rawValue) { state.targetLang = l }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "globe").font(.caption2)
                    Text(state.targetLang.rawValue).font(.caption2)
                }
                .padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary).cornerRadius(5)
            }
            .buttonStyle(.plain)
            Spacer()
            // B2: char count
            if !state.translatedText.isEmpty && !state.isTranslating {
                Text("\(state.translatedText.count) 字符")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if !state.translatedText.isEmpty {
                Button(action: copyResult) {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }.buttonStyle(.borderless)
                .help("拷贝翻译结果")
            }
            Button("重新翻译") { state.translate() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(state.isTranslating || state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Resize grip (C2)

    private var resizeGrip: some View {
        HStack {
            Spacer()
            Image(systemName: "arrowtriangle.down.forward.and.arrowtriangle.up.backward")
                .font(.system(size: 8))
                .foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 4).padding(.bottom, 4)
    }

    // MARK: - Cursor + Copy

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

    private func copyResult() {
        ClipboardMonitor.shared.suppressNext = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.translatedText, forType: .string)
        // D1: Haptic feedback
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
