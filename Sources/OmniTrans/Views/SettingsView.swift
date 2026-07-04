import SwiftUI
import AppKit

/// Settings panel — macOS 26 glass-morphism design.
///
/// - **Background**: `.ultraThinMaterial` — translucent blur, no solid fill.
/// - **Tab bar**: independent `#292a2b` pill capsule, floating above the blur.
/// - **Content**: transparent on the blur canvas.
/// - **Corners**: large continuous-curve radius (20 pt), clipped cleanly.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    @State private var selectedTab = 0
    @Namespace private var tabNamespace
    @AppStorage("max_history_count") private var maxHistoryCount = 100
    @AppStorage("history_disabled") private var historyDisabled = false
    @AppStorage("custom_prompt_enabled") private var customPromptEnabled = false
    @AppStorage("custom_prompt_text") private var customPromptText = ""
    @AppStorage("is_context_aware") private var isContextAware = true
    @AppStorage("context_intensity") private var contextIntensity = 2
    @AppStorage("cache_enabled") private var cacheEnabled = true
    @State private var maxHistoryText: String = "100"

    /// macOS 26 large continuous corner radius.
    private let windowRadius: CGFloat = 20

    private let tabItems = [
        (title: "翻译",    icon: "arrow.triangle.2.circlepath"),
        (title: "API 配置", icon: "server.rack"),
        (title: "通用",    icon: "gearshape"),
        (title: "关于",    icon: "info.circle"),
    ]

    var body: some View {
        ZStack {
            // ── Blur canvas ──
            VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                tabPillBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                contentArea
            }
        }
        .frame(width: 440, height: 500)
        .clipShape(RoundedRectangle(cornerRadius: windowRadius, style: .continuous))
        .accentColor(AppTheme.accentAction)
    }

    // MARK: - Tab Pill Bar (independent capsule)

    private var tabPillBar: some View {
        ZStack {
            // Pill background
            HStack(spacing: 2) {
                ForEach(Array(tabItems.enumerated()), id: \.offset) { idx, item in
                    tabButton(idx: idx, item: item)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(AppTheme.cardSurface)
            )

            // Quit button overlay — right edge of the pill area
            HStack {
                Spacer()
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.error.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .help("退出 OmniTrans")
            }
            .padding(.trailing, 8)
        }
    }

    // MARK: - Tab Button

    private func tabButton(idx: Int, item: (title: String, icon: String)) -> some View {
        Button(action: {
            withAnimation(AppTheme.Motion.fluid.gated) { selectedTab = idx }
        }) {
            HStack(spacing: 4) {
                Image(systemName: item.icon).font(.system(size: 10))
                Text(item.title).font(.system(size: 11, weight: selectedTab == idx ? .semibold : .regular))
            }
            .foregroundColor(selectedTab == idx ? .white : AppTheme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Capsule())
            .background(
                ZStack {
                    if selectedTab == idx {
                        Capsule()
                            .fill(AppTheme.accentAction)
                            .matchedGeometryEffect(id: "tabBg", in: tabNamespace)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var contentArea: some View {
        ZStack {
            switch selectedTab {
            case 0: translateSettingsTab
            case 1: APISettingsView(state: state)
            case 2: GeneralSettingsView(state: state)
            case 3: aboutSettingsTab
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .id(selectedTab)
        .animation(AppTheme.Motion.slow.gated, value: selectedTab)
        .transaction { t in if !AnimationGate.isEnabled { t.disablesAnimations = true; t.animation = nil } }
    }

    // MARK: - Translate Settings

    private var isHistoryEnabled: Binding<Bool> {
        Binding(get: { !historyDisabled }, set: { historyDisabled = !$0 })
    }

    private var translateSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Spacing between tab pill and first card
                Color.clear.frame(height: 6)

                settingsCard(title: "词典查词默认模型", icon: "character.book.closed.fill") {
                    Text("查单词时优先使用的模型，留空则跟随当前选择").font(.caption).foregroundColor(AppTheme.textSecondary)
                    if state.enabledProviders.isEmpty {
                        Text("暂无可用模型").font(.caption).foregroundColor(AppTheme.error)
                    } else {
                        Picker("", selection: Binding(get: { state.dictProviderID }, set: { id in state.dictProviderID = id; ProviderStorageManager.saveDictProviderID(id) })) {
                            Text("跟随当前选择").tag(nil as UUID?)
                            ForEach(state.enabledProviders) { p in Text("\(p.name) · \(p.modelName)").tag(p.id as UUID?) }
                        }.pickerStyle(.menu)
                         .tint(AppTheme.accentAction)
                    }
                }
                settingsCard(title: "语言方向", icon: "arrow.left.arrow.right") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("源语言").font(.caption2).foregroundColor(AppTheme.textSecondary)
                            Picker("", selection: $state.sourceLang) { ForEach(TranslationLanguage.allCases) { l in Text(l.rawValue).tag(l) } }
                                .pickerStyle(.menu)
                                .tint(AppTheme.accentAction)
                        }
                        Image(systemName: "arrow.right").foregroundColor(.secondary).padding(.top, 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("目标语言").font(.caption).foregroundColor(AppTheme.textSecondary)
                            Picker("", selection: $state.targetLang) { ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Text(l.rawValue).tag(l) } }
                                .pickerStyle(.menu)
                                .tint(AppTheme.accentAction)
                        }
                    }
                }
                settingsCard(title: "失败自动降级", icon: "arrow.triangle.branch") {
                    toggleRow(title: "启用后当前 API 失败时按列表顺序尝试下一个", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "fallback_on_failure") }, set: { UserDefaults.standard.set($0, forKey: "fallback_on_failure") }))
                }
                settingsCard(title: "上下文感知翻译", icon: "text.viewfinder") {
                    toggleRow(title: "开启后自动截取划词前后文本作为大模型语境参考，可提升翻译准确性", isOn: $isContextAware)
                    if isContextAware {
                        contextIntensitySlider
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                settingsCard(title: "翻译缓存", icon: "archivebox") {
                    VStack(alignment: .leading, spacing: 10) {
                        toggleRow(title: "启用本地翻译缓存，相同文本与语境下直接复用结果，避免重复 API 调用", isOn: $cacheEnabled)
                        Text("关闭后每次翻译都会重新请求 API，适合调试 Prompt 或测试不同模型效果。")
                            .font(.system(size: 11)).foregroundColor(AppTheme.textCaptionGray)
                    }
                }
                settingsCard(title: "自定义翻译提示词", icon: "text.append") {
                    HStack {
                        Text("支持 {sourceLang} / {targetLang} 变量").font(.caption).foregroundColor(AppTheme.textSecondary); Spacer()
                        Toggle("", isOn: $customPromptEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(AppTheme.accentAction)
                    }
                    TextEditor(text: Binding(get: { customPromptEnabled ? (customPromptText.isEmpty ? defaultPrompt() : customPromptText) : defaultPrompt() }, set: { if customPromptEnabled { customPromptText = $0 } }))
                        .font(.system(size: 12, design: .monospaced)).frame(minHeight: 80, maxHeight: 130).scrollContentBackground(.hidden)
                        .padding(4).background(Color.primary.opacity(0.05)).cornerRadius(6)
                        .opacity(customPromptEnabled ? 1.0 : 0.4).disabled(!customPromptEnabled)
                    Button(action: resetCustomPrompt) { Label("恢复默认", systemImage: "arrow.counterclockwise").font(.caption) }.buttonStyle(.borderless).foregroundColor(.secondary)
                }
                settingsCard(title: "翻译历史", icon: "clock.arrow.circlepath") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Text("最大保存条数").font(.system(size: 11)).foregroundColor(AppTheme.textCaptionGray)
                            TextField("", text: $maxHistoryText)
                                .frame(width: 48).textFieldStyle(.roundedBorder).font(.system(size: 12))
                                .onSubmit {
                                    if let v = Int(maxHistoryText), v > 0, v <= 500 { maxHistoryCount = v }
                                    else { maxHistoryText = "\(maxHistoryCount)" }
                                }
                                .onAppear { maxHistoryText = "\(maxHistoryCount)" }
                        }
                        Text("限制内存中保存的历史翻译记录数量（1–500）").font(.system(size: 11)).foregroundColor(AppTheme.textCaptionGray)
                        Divider()
                        toggleRow(title: "启用翻译历史记录，保存每次翻译结果以便回溯", isOn: isHistoryEnabled)
                        if historyDisabled {
                            Text("翻译历史已关闭，新的翻译结果将不会被保存。").font(.system(size: 11)).foregroundColor(AppTheme.textCaptionGray)
                        }
                    }
                }
            }.padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    // MARK: - About

    private var aboutSettingsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let path = Bundle.main.path(forResource: "icon", ofType: "icns"),
                   let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage).resizable().frame(width: 72, height: 72).cornerRadius(16).shadow(radius: 4)
                } else {
                    Image(systemName: "character.bubble.fill").font(.system(size: 48)).foregroundColor(AppTheme.accentAction)
                }
                Text("OmniTrans").font(.title2).bold()
                Text("v\(kAppVersion)").font(.subheadline).foregroundColor(AppTheme.textSecondary)
                Text("菜单栏翻译 · 划词 · OCR · 词典 · TTS · 多引擎").font(.caption).foregroundColor(AppTheme.textSecondary)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    FeatureRow(icon: "text.bubble", text: "划词翻译 — \(HotkeyManager.hotkeyLabel()) 选中即译")
                    FeatureRow(icon: "rectangle.dashed", text: "OCR 框选 — \(HotkeyManager.ocrHotkeyLabel()) 框选屏幕取字")
                    FeatureRow(icon: "arrow.triangle.swap", text: "原位替换 — \(HotkeyManager.replaceHotkeyLabel()) 直接粘贴译文")
                    FeatureRow(icon: "character.book.closed", text: "智能词典 — 自动检测单词，结构化释义 + 音标 + 例句")
                    FeatureRow(icon: "speaker.wave.2", text: "TTS 朗读 — 翻译结果与词典词汇一键朗读")
                    FeatureRow(icon: "globe", text: "9 个引擎 — OpenAI · Claude · Gemini · 通义 · DeepSeek · 火山 · Google · Bing · 阿里")
                    FeatureRow(icon: "arrow.triangle.branch", text: "智能降级 — AI → MT → 原生引擎逐级回退")
                    FeatureRow(icon: "cpu", text: "原生引擎 — macOS 内置词典 + Translation API")
                    FeatureRow(icon: "text.quote", text: "场景预设 — 翻译/润色/口语/代码/文案 5 种 Prompt")
                    FeatureRow(icon: "rectangle.expand.vertical", text: "动态窗口 — 小/默认/大/动态 四种尺寸")
                    FeatureRow(icon: "rectangle.on.rectangle", text: "剪贴板监听 — 后台 0% CPU · NSWorkspace 通知驱动")
                    FeatureRow(icon: "arrow.up.arrow.down", text: "拖动排序 — API 配置卡片自由重排，持久化保存")
                    FeatureRow(icon: "lock.shield", text: "隐私 — AES-256-GCM 文件加密，密钥绑定 IOPlatformUUID")
                }
                Divider()
                Text("OmniTrans · SwiftUI · 零第三方依赖 · 2026").font(.caption2).foregroundColor(AppTheme.textSecondary)
                Divider()
                Button(action: {
                    UserDefaults.standard.set(false, forKey: "has_completed_onboarding")
                    let a = NSAlert()
                    a.messageText = "已重置引导页"
                    a.informativeText = "下次启动时将重新显示首次使用引导。"
                    a.alertStyle = .informational
                    a.addButton(withTitle: "好的")
                    a.runModal()
                }) {
                    Label("重置首次使用引导", systemImage: "arrow.counterclockwise").font(.caption)
                }.buttonStyle(.borderless).foregroundColor(.secondary)
            }.padding()
        }
    }

    // MARK: - Context Intensity Slider

    private var contextIntensitySlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(value: Binding(get: { Double(contextIntensity) }, set: { contextIntensity = Int($0.rounded()) }), in: 0...4, step: 1)
                .tint(AppTheme.accentAction)
            HStack(spacing: 0) {
                ForEach(0..<5) { tier in
                    Text("\([100,200,300,400,500][tier])")
                        .font(.system(size: 11))
                        .foregroundColor(contextIntensity == tier ? AppTheme.accentAction : AppTheme.textCaptionGray)
                        .frame(maxWidth: .infinity, alignment: tier == 0 ? .leading : tier == 4 ? .trailing : .center)
                }
            }
            Text("提示：上下文感知强度开得越高，单次请求消耗的 Token 越大，但翻译的术语准确性与连贯性越高。")
                .font(.system(size: 11)).foregroundColor(AppTheme.textCaptionGray).fixedSize(horizontal: false, vertical: true)
        }
        .animation(AppTheme.Motion.snip.gated, value: contextIntensity)
    }

    // MARK: - Helpers

    private func settingsCard<C: View>(title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            Label(title, systemImage: icon).font(.subheadline).bold().foregroundColor(AppTheme.textPrimary)
            content()
        }.nativeCardStyle()
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundColor(AppTheme.textCaptionGray).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(AppTheme.accentAction)
        }
    }

    private func defaultPrompt() -> String {
        "You are a professional translator. Translate the following text to {targetLang} accurately and concisely. Preserve the original meaning, tone, and formatting. Output only the translation without any explanations, notes, or markdown fences."
    }
    private func resetCustomPrompt() { customPromptText = defaultPrompt() }
}

private struct FeatureRow: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 18).foregroundColor(AppTheme.accentAction).font(.caption)
            Text(text).font(.caption).foregroundColor(AppTheme.textPrimary)
        }
    }
}

// MARK: - Visual Effect Blur (NSViewRepresentable)

/// Lightweight translucent blur backed by `NSVisualEffectView`.
/// Used as the canvas background for the macOS 26 glass-morphism look.
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

