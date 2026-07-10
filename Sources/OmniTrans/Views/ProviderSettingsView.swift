import SwiftUI

// MARK: - Provider Settings View (API Config Tab)

/// Full API configuration with editable cards, reorder, connectivity test,
/// model detection, two-step delete, and template library.
struct ProviderSettingsView: View {
    @ObservedObject var state: AppState
    @State private var expandedProviderID: UUID?
    @State private var showTemplatePicker = false
    @State private var testResults: [UUID: APITestResult] = [:]
    @State private var confirmDeleteID: UUID?
    @State private var fetchedModels: [UUID: [String]] = [:]
    @State private var isFetchingModels: Set<UUID> = []

    /// Namespace for `matchedGeometryEffect` — powers smooth card reorder animations.
    @Namespace private var cardNamespace

    enum APITestResult { case testing; case success(latency: Double); case failure(String) }

    private var nativeProvider: APIProvider? { state.providers.first { $0.isBuiltIn } }
    private var mutableProviders: [APIProvider] { state.providers.filter { !$0.isBuiltIn } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let native = nativeProvider {
                nativeLockedCard(native)
            }

            if !mutableProviders.isEmpty {
                HStack {
                    Text("已配置的服务")
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                    Spacer()
                    Text("双击卡片展开编辑")
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.top, 4)

                ForEach(mutableProviders) { provider in
                    providerCard(provider)
                        .matchedGeometryEffect(id: provider.id, in: cardNamespace)
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .move(edge: .bottom))
                                .animation(AppTheme.Motion.fluid.resolve().delay(0.08)),
                            removal: .opacity
                                .combined(with: .move(edge: .top))
                                .animation(AppTheme.Motion.toggleCollapse.resolve())
                        ))
                }
                .animation(AppTheme.Motion.fluid.resolveGated(), value: state.providers.map(\.id))
            }

            Button {
                showTemplatePicker = true
            } label: {
                Label("添加翻译服务", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showTemplatePicker) { templatePickerSheet }
    }

    // MARK: - Native Card

    private func nativeLockedCard(_ p: APIProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .bold)).foregroundColor(.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 13, weight: .semibold))
                Text(p.modelName).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundColor(.secondary)
            Toggle("", isOn: .constant(true)).toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(true)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .cardShadow()
    }

    // MARK: - Provider Card

    @ViewBuilder
    private func providerCard(_ provider: APIProvider) -> some View {
        let isExpanded = expandedProviderID == provider.id
        let deleting = confirmDeleteID == provider.id
        let testResult = testResults[provider.id]

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(spacing: 0) { moveUpButton(provider); moveDownButton(provider) }
                Image(systemName: iconForKind(provider.kind)).font(.system(size: 13)).foregroundColor(.accentColor).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(provider.name.isEmpty ? "未命名" : provider.name).font(.system(size: 12, weight: .semibold))
                        kindBadge(provider.kind)
                    }
                    Text(provider.modelName).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                if case .success(let ms) = testResult {
                    Text("\(String(format: "%.0f", ms * 1000))ms").font(.system(size: 10, design: .monospaced)).foregroundColor(.green)
                } else if case .failure = testResult {
                    Text("失败").font(.system(size: 10)).foregroundColor(.red)
                }
                connectivityButton(provider)
                Toggle("", isOn: Binding(get: { provider.isEnabled }, set: { v in var p = provider; p.isEnabled = v; state.updateProvider(p) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                deleteButton(provider, deleting: deleting)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .cardShadow()
            .onTapGesture(count: 2) {
                withAnimation(AppTheme.Motion.cardExpand.resolveGated()) {
                    expandedProviderID = isExpanded ? nil : provider.id
                }
            }

            if isExpanded {
                providerEditor(provider).padding(.top, 6)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Move

    private func moveUpButton(_ p: APIProvider) -> some View {
        Button {
            guard let idx = state.providers.firstIndex(of: p), idx > 1 else { return }
            withAnimation(AppTheme.Motion.fluid.resolveGated()) {
                state.providers.swapAt(idx, idx - 1); state.save()
            }
        } label: {
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).frame(width: 14, height: 14).contentShape(Rectangle())
        }.buttonStyle(.borderless)
    }

    private func moveDownButton(_ p: APIProvider) -> some View {
        Button {
            guard let idx = state.providers.firstIndex(of: p), idx < state.providers.count - 1 else { return }
            withAnimation(AppTheme.Motion.fluid.resolveGated()) {
                state.providers.swapAt(idx, idx + 1); state.save()
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).frame(width: 14, height: 14).contentShape(Rectangle())
        }.buttonStyle(.borderless)
    }

    // MARK: - Connectivity

    private func connectivityButton(_ p: APIProvider) -> some View {
        Button {
            testResults[p.id] = .testing
            Task {
                let r = await APITestService.testConnection(for: p)
                await MainActor.run {
                    switch r {
                    case .success(let l): testResults[p.id] = .success(latency: l)
                    case .failure(let m): testResults[p.id] = .failure(m)
                    }
                    Task { try? await Task.sleep(nanoseconds: 5_000_000_000); await MainActor.run { testResults[p.id] = nil } }
                }
            }
        } label: {
            if case .testing = testResults[p.id] {
                ProgressView().scaleEffect(0.5).frame(width: 18, height: 18)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 10))
            }
        }
        .buttonStyle(.borderless).help("测试连通性").disabled(testResults[p.id] != nil)
    }

    // MARK: - Delete

    private func deleteButton(_ p: APIProvider, deleting: Bool) -> some View {
        Group {
            if deleting {
                Button {
                    state.deleteProvider(p); confirmDeleteID = nil
                    if expandedProviderID == p.id { expandedProviderID = nil }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash.fill").font(.system(size: 8))
                        Text("确认").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.red))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    confirmDeleteID = p.id
                    Task { let t = p.id; try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run { if confirmDeleteID == t { confirmDeleteID = nil } } }
                } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(4).background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
                }
                .buttonStyle(.plain).help("删除")
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func providerEditor(_ p: APIProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            editorField("名称") { TextField("", text: bind(p, \.name)).textFieldStyle(.roundedBorder) }
            editorField("类型") {
                Picker("", selection: bind(p, \.kind, onSet: { k in
                    var updated = p; updated.kind = k
                    if updated.baseURL.isEmpty { updated.baseURL = k.defaultBaseURL }
                    if updated.modelName.isEmpty { updated.modelName = k.defaultModel }
                    state.updateProvider(updated)
                })) {
                    ForEach(ProviderKind.allCases.filter { $0 != .macOSNative }) { k in Text(k.rawValue).tag(k) }
                }.pickerStyle(.menu).frame(width: 140)
            }
            editorField("地址") { TextField("", text: bind(p, \.baseURL)).textFieldStyle(.roundedBorder) }
            if p.kind == .ollama {
                HStack(spacing: 8) {
                    Text("Key").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
                    SecureField("可选——本地 Ollama 通常不需要", text: bind(p, \.apiKey))
                        .textFieldStyle(.roundedBorder)
                        .help("Ollama >=0.4 可配置 API Key，留空即可")
                }
            } else {
                editorField("Key") { SecureField("", text: bind(p, \.apiKey)).textFieldStyle(.roundedBorder) }
            }
            if p.kind == .alibabaMT || p.kind == .volcengineMT {
                editorField("Secret") { SecureField("", text: bind(p, \.apiSecret)).textFieldStyle(.roundedBorder) }
            }
            if p.kind == .bingMT {
                editorField("区域") { TextField("", text: bind(p, \.customRegion)).textFieldStyle(.roundedBorder) }
            }

            // Model fetch + picker
            HStack(alignment: .center, spacing: 8) {
                Text("模型").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).frame(width: 56, alignment: .leading)

                if let models = fetchedModels[p.id], !models.isEmpty {
                    Picker("", selection: bind(p, \.modelName)) {
                        ForEach(models, id: \.self) { m in Text(m).tag(m) }
                    }
                    .pickerStyle(.menu)
                } else {
                    TextField("", text: bind(p, \.modelName)).textFieldStyle(.roundedBorder)
                }

                Button {
                    isFetchingModels.insert(p.id)
                    Task {
                        let result = await APITestService.fetchModels(for: p)
                        await MainActor.run {
                            isFetchingModels.remove(p.id)
                            if case .success(let models) = result { fetchedModels[p.id] = models }
                        }
                    }
                } label: {
                    if isFetchingModels.contains(p.id) {
                        ProgressView().scaleEffect(0.6).frame(width: 22, height: 22)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "magnifyingglass").font(.system(size: 9))
                            Text("检测").font(.system(size: 9))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
                    }
                }
                .buttonStyle(.plain).help("检测可用模型")
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func editorField(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
            field()
        }
    }

    // MARK: - Bindings

    private func bind(_ p: APIProvider, _ kp: WritableKeyPath<APIProvider, String>, onSet: ((ProviderKind) -> Void)? = nil) -> Binding<String> {
        Binding(get: { p[keyPath: kp] }, set: { v in
            var updated = p; updated[keyPath: kp] = v; state.updateProvider(updated)
        })
    }

    private func bind(_ p: APIProvider, _ kp: WritableKeyPath<APIProvider, ProviderKind>, onSet: @escaping (ProviderKind) -> Void) -> Binding<ProviderKind> {
        Binding(get: { p[keyPath: kp] }, set: { k in onSet(k) })
    }

    // MARK: - Helpers

    private func kindBadge(_ kind: ProviderKind) -> some View {
        Text(kind.rawValue).font(.system(size: 8, weight: .bold)).foregroundColor(.accentColor)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.1)).clipShape(Capsule())
    }

    private func iconForKind(_ kind: ProviderKind) -> String {
        switch kind {
        case .openAI, .openAICompat: "brain"; case .ollama: "desktopcomputer"; case .anthropic: "sparkles"; case .gemini: "star"
        case .macOSNative: "apple.logo"; case .googleMT: "g.circle"; case .bingMT: "b.circle"
        case .alibabaMT: "a.circle"; case .volcengineMT: "v.circle"
        }
    }

    // MARK: - Template Picker

    private var templatePickerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("选择服务模板").font(.system(size: 13, weight: .bold))
                Spacer()
                Button("取消") { showTemplatePicker = false }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    templateSection("AI 大语言模型") {
                        tpl("Ollama (本地)", icon: "desktopcomputer", kind: .ollama, baseURL: "http://127.0.0.1:11434/v1", models: ["qwen2.5", "llama3.2"], desc: "【本地离线】macOS 本地运行开源模型，无需联网和 API Key")
                        tpl("DeepSeek", icon: "d.square", kind: .openAICompat, baseURL: "https://api.deepseek.com/v1", models: ["deepseek-v4-flash", "deepseek-v4-pro"], desc: "【推荐】中文与技术文档翻译王牌，V4 闪电版极适合高频划词")
                        tpl("Zhipu AI (智谱)", icon: "z.square", kind: .openAICompat, baseURL: "https://open.bigmodel.cn/api/paas/v4", models: ["glm-4-flash", "glm-4-9b-chat"], desc: "【免费战神】glm-4-flash 官方长期免费，极具性价比的免成本查词首选")
                        tpl("SiliconFlow (硅基流动)", icon: "s.square", kind: .openAICompat, baseURL: "https://api.siliconflow.cn/v1", models: ["deepseek-ai/DeepSeek-V3", "Qwen/Qwen2.5-72B-Instruct"], desc: "【一站式聚合】千万级 Token 免费赠送，聚合各大开源顶流模型")
                        tpl("Google Gemini", icon: "star", kind: .openAICompat, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", models: ["gemini-3.5-flash", "gemini-2.5-pro"], desc: "【原生兼容端点】3.5 Flash 响应极速，Pro 版百万超长上下文")
                        tpl("OpenAI", icon: "brain", kind: .openAI, baseURL: "https://api.openai.com/v1", models: ["gpt-4o-mini", "gpt-4o"], desc: "【行业标杆】工业级稳定格式保留，复杂 Markdown 及代码注释翻译首选")
                        tpl("Groq", icon: "g.square", kind: .openAICompat, baseURL: "https://api.groq.com/openai/v1", models: ["llama-3.3-70b-versatile", "mixtral-8x7b-32768"], desc: "【极致速度】基于 LPU 硬件加速，Token 返回速度飙破 400+/s")
                        tpl("Alibaba Qwen (百炼)", icon: "a.square", kind: .openAICompat, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", models: ["qwen-plus", "qwen-max"], desc: "【多语言专家】通义千问官方兼容端点，亚洲语言及日韩欧洲小语种表现极佳")
                    }
                    Divider().padding(.horizontal, 20)
                    templateSection("机器翻译") {
                        tpl("Google 翻译", icon: "g.circle", kind: .googleMT, desc: "Cloud Translation v2")
                        tpl("Bing 翻译", icon: "b.circle", kind: .bingMT, desc: "Microsoft Translator v3")
                        tpl("阿里云翻译", icon: "a.circle", kind: .alibabaMT, desc: "阿里云 MT")
                        tpl("火山翻译", icon: "v.circle", kind: .volcengineMT, desc: "Volcengine MT")
                    }
                }.padding(.vertical, 12)
            }
        }
        .frame(width: 440, height: 520).background(.regularMaterial)
    }

    private func templateSection(_ title: String, @ViewBuilder items: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                .padding(.horizontal, 24).padding(.bottom, 8)
            items()
        }
    }

    private func tpl(_ name: String, icon: String, kind: ProviderKind, baseURL: String? = nil, models: [String] = [], desc: String) -> some View {
        Button {
            var p = APIProvider.blank(kind: kind)
            p.name = name
            if let url = baseURL { p.baseURL = url }
            if !models.isEmpty { p.modelName = models[0] }
            state.addProvider(p)
            showTemplatePicker = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(.accentColor).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundColor(.primary)
                    Text(desc).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer(); Image(systemName: "plus").font(.system(size: 10)).foregroundColor(.accentColor)
            }
            .padding(.horizontal, 24).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
