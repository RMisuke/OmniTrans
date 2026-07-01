import SwiftUI

struct OnboardingView: View {
    let onDismiss: () -> Void
    @State private var page = 0
    private let totalPages = 3

    var body: some View {
        VStack(spacing: 0) {
            // ── Content ──
            ZStack {
                if page == 0 { welcomePage.transition(.opacity) }
                if page == 1 { securityPage.transition(.opacity) }
                if page == 2 { featuresPage.transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.25), value: page)
            .frame(minHeight: 420)

            Divider()

            // ── Footer ──
            HStack {
                // Page dots
                HStack(spacing: 6) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("上一步") { withAnimation { page -= 1 } }
                        .buttonStyle(.borderless).controlSize(.large)
                }
                if page < totalPages - 1 {
                    Button("下一步") { withAnimation { page += 1 } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("开始使用 OmniTrans") { onDismiss() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 16)
        }
        .frame(width: 600)
    }

    // MARK: - Page 0 — Welcome

    private var welcomePage: some View {
        VStack(spacing: 20) {
            // App icon
            if let iconPath = Bundle.main.path(forResource: "icon", ofType: "icns"),
               let nsImage = NSImage(contentsOfFile: iconPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .cornerRadius(16)
                    .shadow(radius: 3)
            } else {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
            }

            Text("欢迎使用 OmniTrans")
                .font(.system(size: 26, weight: .bold))

            Text("AI 驱动的智能翻译工具，集成在菜单栏中随时调用")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 14) {
                OnboardRow(
                    icon: "text.bubble.fill",
                    color: .blue,
                    title: "划词翻译",
                    desc: "选中任意文本，按下 \(HotkeyManager.hotkeyLabel()) 即刻弹出悬浮翻译窗"
                )
                OnboardRow(
                    icon: "rectangle.dashed",
                    color: .orange,
                    title: "OCR 框选翻译",
                    desc: "按下 \(HotkeyManager.ocrHotkeyLabel()) 拖拽框选屏幕任意区域，识别图片与 PDF 文字"
                )
                OnboardRow(
                    icon: "character.book.closed.fill",
                    color: .purple,
                    title: "智能词典",
                    desc: "输入单词自动切换词典模式，显示音标、释义、例句"
                )
            }
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 30)
    }

    // MARK: - Page 1 — Permissions & Security

    private var securityPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("隐私与安全")
                .font(.system(size: 24, weight: .bold))

            Text("OmniTrans 将您的隐私放在首位")
                .font(.system(size: 15))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                OnboardRow(
                    icon: "key.horizontal",
                    color: .green,
                    title: "AES-256 本地加密",
                    desc: "API 密钥使用 AES-256-GCM 加密存储在本机，密钥绑定硬件标识，其他应用或用户无法读取"
                )
                OnboardRow(
                    icon: "network.slash",
                    color: .indigo,
                    title: "无数据收集",
                    desc: "翻译请求通过 HTTPS 直连 API 服务商，不经过任何中间服务器。软件无埋点，不上传任何数据"
                )
                OnboardRow(
                    icon: "hand.raised.slash.fill",
                    color: .orange,
                    title: "按需授权",
                    desc: "首次使用时按需申请辅助功能与屏幕录制权限，权限仅用于取词翻译，不记录屏幕内容"
                )
            }
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 30)
    }

    // MARK: - Page 2 — Features

    private var featuresPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.purple)

            Text("强大的翻译能力")
                .font(.system(size: 24, weight: .bold))

            Text("集成多种翻译引擎，覆盖所有使用场景")
                .font(.system(size: 15))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                OnboardRow(
                    icon: "cpu.fill",
                    color: .blue,
                    title: "12+ AI 大模型",
                    desc: "OpenAI · Claude · Gemini · 通义千问 · DeepSeek · SenseNova 等，支持流式输出"
                )
                OnboardRow(
                    icon: "globe",
                    color: .green,
                    title: "3 种机器翻译",
                    desc: "Google Translate · Bing Translator · 阿里云机器翻译，稳定可靠"
                )
                OnboardRow(
                    icon: "apple.logo",
                    color: .gray,
                    title: "macOS 原生引擎",
                    desc: "内置系统离线词典与神经网络翻译，零网络、零 Token 消耗"
                )
                OnboardRow(
                    icon: "gearshape.fill",
                    color: .secondary,
                    title: "灵活配置",
                    desc: "词典/翻译模式可独立选模型 · 深色/浅色主题 · 自定义提示词 · 翻译历史回溯"
                )
            }
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 30)
    }
}

// MARK: - Reusable row

private struct OnboardRow: View {
    let icon: String
    let color: Color
    let title: String
    let desc: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }
}
