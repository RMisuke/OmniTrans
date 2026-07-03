import SwiftUI
import ApplicationServices

struct OnboardingView: View {
    let onDismiss: () -> Void
    @State private var page = 0
    private let totalPages = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if page == 0 { welcomePage.transition(.opacity) }
                if page == 1 { securityPage.transition(.opacity) }
                if page == 2 { permissionsPage.transition(.opacity) }
                if page == 3 { offlineTranslationPage.transition(.opacity) }
                if page == 4 { featuresPage.transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.25), value: page)
            .frame(minHeight: 420)

            Divider()

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("上一步") { withAnimationGated(.default) { page -= 1 } }
                        .buttonStyle(.borderless).controlSize(.large)
                }
                if page < totalPages - 1 {
                    Button("下一步") { withAnimationGated(.default) { page += 1 } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("开始使用 OmniTrans") { onDismiss() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 16)
        }
        .frame(width: 640)
        .onChange(of: page) { _, newPage in
            if newPage == 2 { requestPermissions() }
        }
    }

    // MARK: - Permissions trigger

    private func requestPermissions() {
        // Accessibility permission
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        // Screen recording permission — triggered automatically by macOS
        // when the user first uses OCR (no manual API to pre-request it)
    }

    // MARK: - Page 0 — Welcome

    private var welcomePage: some View {
        VStack(spacing: 20) {
            if let iconPath = Bundle.main.path(forResource: "icon", ofType: "icns"),
               let nsImage = NSImage(contentsOfFile: iconPath) {
                Image(nsImage: nsImage)
                    .resizable().frame(width: 72, height: 72)
                    .cornerRadius(16).shadow(radius: 3)
            } else {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 56)).foregroundColor(.accentColor)
            }
            Text("欢迎使用 OmniTrans")
                .font(.system(size: 26, weight: .bold))
            Text("菜单栏常驻 · 9 种翻译引擎 · 零第三方依赖 · 纯 Swift 原生")
                .font(.system(size: 15)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            VStack(alignment: .leading, spacing: 14) {
                                    OnboardRow(
                        icon: "text.bubble.fill",
                        color: .blue,
                        title: "划词翻译",
                        desc: "选中任意文本，按下 \(HotkeyManager.hotkeyLabel()) 即刻弹出悬浮翻译窗，支持流式输出"
                    )
                    OnboardRow(
                        icon: "rectangle.dashed",
                        color: .orange,
                        title: "OCR 框选翻译",
                        desc: "按下 \(HotkeyManager.ocrHotkeyLabel()) 框选屏幕任意区域，VisionOCR 识别文字后自动翻译"
                    )
                    OnboardRow(
                        icon: "arrow.triangle.swap",
                        color: .green,
                        title: "原位替换",
                        desc: "按下 \(HotkeyManager.replaceHotkeyLabel()) 将译文直接粘贴替换原文，无需手动操作"
                    )
        }
        .padding(.horizontal, 40)
    }
    .padding(.vertical, 30)
    }

    // MARK: - Page 1 — Security

    private var securityPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48)).foregroundColor(.green)
            Text("隐私与安全")
                .font(.system(size: 24, weight: .bold))
            Text("OmniTrans 将您的隐私放在首位")
                .font(.system(size: 15)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                OnboardRow(icon: "key.horizontal", color: .green,
                    title: "AES-256 本地加密",
                    desc: "API 密钥使用 AES-256-GCM 文件加密（弃用 Keychain），密钥绑定 IOPlatformUUID")
                OnboardRow(icon: "network.slash", color: .indigo,
                    title: "无数据收集",
                    desc: "翻译请求通过 HTTPS 直连 API 服务商，不经过任何中间服务器。软件无埋点，不上传任何数据")
                OnboardRow(icon: "hand.raised.slash.fill", color: .orange,
                    title: "按需授权",
                    desc: "权限仅用于取词翻译与 OCR 识别，不记录屏幕内容")
            }
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 30)
    }

    // MARK: - Page 2 — Permissions

    private var permissionsPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48)).foregroundColor(.blue)
            Text("权限设置")
                .font(.system(size: 24, weight: .bold))
            Text("OmniTrans 需要以下权限才能正常工作")
                .font(.system(size: 15)).foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                OnboardRow(icon: "hand.tap.fill", color: .blue,
                    title: "辅助功能权限",
                    desc: "用于读取划词选中的文本内容。系统弹窗已自动打开，请在隐私设置中勾选 OmniTrans")
                OnboardRow(icon: "rectangle.inset.filled", color: .orange,
                    title: "屏幕录制权限",
                    desc: "用于 OCR 框选识别屏幕上的文字。首次使用 OCR 时将自动弹出系统授权弹窗")
                OnboardRow(icon: "info.circle.fill", color: .secondary,
                    title: "随时可在系统设置中修改",
                    desc: "打开 系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制 即可管理")
            }
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 30)
    }

    // MARK: - Page 3 — Offline Translation

    private var offlineTranslationPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48)).foregroundColor(.accentColor)
            Text("离线翻译设置")
                .font(.system(size: 24, weight: .bold))
            Text("macOS 原生离线翻译需要先下载语言包")
                .font(.system(size: 15)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                OnboardRow(icon: "apple.logo", color: .blue,
                    title: "完全离线 · 零延迟",
                    desc: "基于 Apple 芯片 ANE 神经网络引擎，翻译不消耗大模型 Token，无网络流量")
                OnboardRow(icon: "arrow.down.to.line.compact", color: .orange,
                    title: "首次使用需下载语言包",
                    desc: "打开 系统设置 → 通用 → 语言与地区 → 翻译语言，下载中英文等所需语言模型")
                OnboardRow(icon: "exclamationmark.triangle.fill", color: .red,
                    title: "未下载将无法使用离线翻译",
                    desc: "若未安装语言包，翻译将超时并提示引导。可随时切换至云端 API 继续使用")
                OnboardRow(icon: "checkmark.shield.fill", color: .green,
                    title: "语言包仅需下载一次",
                    desc: "每个语言对约几百 MB，下载后永久可用，系统更新后自动保留")
            }
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 30)
    }

    // MARK: - Page 4 — Features

    private var featuresPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 48)).foregroundColor(.purple)
            Text("全栈翻译能力")
                .font(.system(size: 24, weight: .bold))
            Text("策略工厂 + 三级降级 + 解析器抽象，覆盖所有场景")
                .font(.system(size: 15)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 12) {                    OnboardRow(
                        icon: "cpu.fill",
                        color: .blue,
                        title: "AI 大模型 + 兼容 API",
                        desc: "OpenAI · Claude · Gemini · 通义千问 · DeepSeek · SenseNova 等，支持 OpenAI 兼容协议自定义接入"
                    )
                    OnboardRow(
                        icon: "globe",
                        color: .green,
                        title: "MT 机器翻译",
                        desc: "Google Translate · Bing Translator · 阿里云翻译 · 火山翻译（HMAC-SHA256 签名），无需 API Key"
                    )
                    OnboardRow(
                        icon: "apple.logo",
                        color: .gray,
                        title: "macOS 原生引擎",
                        desc: "内置系统离线词典与 Translation API，零网络、零 Token 消耗，绝对兜底"
                    )
                    OnboardRow(
                        icon: "arrow.triangle.branch",
                        color: .orange,
                        title: "智能降级",
                        desc: "按 API 配置列表顺序逐一下滑重试，失败即时切换 Provider，可手动关闭降级"
                    )
                    OnboardRow(
                        icon: "rectangle.expand.vertical",
                        color: .indigo,
                        title: "动态窗口 + 场景预设",
                        desc: "小 / 默认 / 大 / 动态 四种尺寸；翻译/润色/口语/代码/文案 5 种 Prompt 模板"
                    )
                    OnboardRow(
                        icon: "gearshape.fill",
                        color: .secondary,
                        title: "灵活配置",
                        desc: "API 卡片拖动排序 · 三种快捷键可录制 · AES-256 加密 · 历史回溯 · 深色/浅色主题 · 剪贴板监听"
                    )
                }
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 30)
    }
}

// MARK: - Reusable row

private struct OnboardRow: View {
    let icon: String; let color: Color; let title: String; let desc: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(color).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(desc).font(.system(size: 13)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05)).cornerRadius(8)
    }
}
