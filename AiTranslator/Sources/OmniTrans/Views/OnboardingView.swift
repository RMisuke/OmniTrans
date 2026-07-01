import SwiftUI
import AppKit

struct OnboardingView: View {
    let onDismiss: () -> Void

    @State private var page = 0
    private let totalPages = 3

    var body: some View {
        VStack(spacing: 0) {
            // Page content — manual paging for macOS compatibility
            ZStack {
                switch page {
                case 0: permissionsPage
                case 1: securityPage
                case 2: usagePage
                default: EmptyView()
                }
            }
            .frame(minHeight: 520)
            .animation(.easeInOut(duration: 0.25), value: page)

            Divider()

            // Bottom bar
            HStack {
                // Page dots
                HStack(spacing: 6) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut(duration: 0.2), value: page)
                    }
                }

                Spacer()

                if page > 0 {
                    Button("上一步") { withAnimation { page -= 1 } }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .buttonStyle(.borderless)
                        .controlSize(.large)
                }

                if page < totalPages - 1 {
                    Button("下一步") { withAnimation { page += 1 } }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("开始使用") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 560)
    }

    // MARK: - Page 1: Permissions

    private var permissionsPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.slash")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
                .padding(.top, 12)

            Text("需要两项系统权限")
                .font(.title2)
                .bold()

            Text("OmniTrans通过快捷键和划词取词工作，需要以下权限才能正常运行")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 16) {
                permissionRow(
                    icon: "accessibility",
                    title: "辅助功能权限",
                    desc: "用于读取其他应用中的选中文本",
                    action: "系统设置 → 隐私与安全性 → 辅助功能",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "屏幕录制权限",
                    desc: "用于 OCR 识别无法直接选中的文本（如图片中的文字）",
                    action: "系统设置 → 隐私与安全性 → 屏幕录制",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            }
            .padding(.horizontal, 20)

            Text("权限仅用于翻译功能，不会记录或上传屏幕内容")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func permissionRow(icon: String, title: String, desc: String, action: String, url: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout).bold()
                Text(desc).font(.caption).foregroundColor(.secondary)
                Button {
                    if let u = URL(string: url) {
                        NSWorkspace.shared.open(u)
                    }
                } label: {
                    Text(action).font(.caption2)
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - Page 2: Security

    private var securityPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 48))
                .foregroundColor(.green)
                .padding(.top, 12)

            Text("API 密钥安全存储")
                .font(.title2)
                .bold()

            Text("你的 API 密钥将加密保存在系统钥匙串中")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 16) {
                securityRow(
                    icon: "lock.shield",
                    title: "钥匙串加密",
                    desc: "所有 API 密钥使用 macOS 钥匙串加密存储，与 iCloud 钥匙串同步，安全可靠"
                )
                securityRow(
                    icon: "eye.slash",
                    title: "仅本地使用",
                    desc: "密钥仅在调用 AI API 时通过 HTTPS 发送，不会上传至任何第三方服务器"
                )
                securityRow(
                    icon: "touchid",
                    title: "输入钥匙串密码",
                    desc: "保存 API 密钥时，系统可能会提示输入登录密码或使用 Touch ID 授权"
                )
            }
            .padding(.horizontal, 20)

            Text("钥匙串密码即 Mac 登录密码")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func securityRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.green)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout).bold()
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - Page 3: Usage

    private var usagePage: some View {
        VStack(spacing: 20) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundColor(.purple)
                .padding(.top, 12)

            Text("快速上手")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 16) {
                usageRow(
                    icon: "command",
                    title: "快捷键翻译",
                    desc: "在任意应用中选中文本，按下 \(HotkeyManager.hotkeyLabel()) 即可弹出翻译悬浮窗"
                )
                usageRow(
                    icon: "rectangle.dashed",
                    title: "OCR 框选翻译",
                    desc: "按下 \(HotkeyManager.ocrHotkeyLabel())，鼠标拖拽框选屏幕区域，自动 OCR 识别并翻译（适合图片、PDF 中的文字）"
                )
                usageRow(
                    icon: "doc.on.clipboard",
                    title: "剪贴板监听",
                    desc: "开启后在设置中启用「自动翻译拷贝内容」，复制文本即自动翻译"
                )
                usageRow(
                    icon: "gearshape",
                    title: "配置 API",
                    desc: "在设置 → API 配置中添加 AI 服务商，支持 OpenAI、Claude、Gemini 及国内主流模型"
                )
                usageRow(
                    icon: "rectangle.3.group",
                    title: "悬浮窗操作",
                    desc: "翻译结果直接在悬浮窗显示，可切换语言、拷贝结果，按 Esc 或点击外部关闭"
                )
            }
            .padding(.horizontal, 20)

            Text("点击菜单栏 💬 图标也可打开完整翻译窗口")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func usageRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.purple)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout).bold()
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}
