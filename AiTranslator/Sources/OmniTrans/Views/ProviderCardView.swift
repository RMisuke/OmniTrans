import SwiftUI

/// Self-contained card for one provider — handles edit / delete / test / fetch-models
struct ProviderCardView: View {
    let provider: APIProvider
    let allEnabled: [APIProvider]
    let onUpdate: (APIProvider) -> Void
    let onDelete: (APIProvider) -> Void
    /// Called to lazily load API key from Keychain when not already in memory
    let onLoadKey: ((UUID) -> String)?

    // ── Local edit state ──
    @State private var isEditing = false
    @State private var editName: String = ""
    @State private var editKind: ProviderKind = .openAI
    @State private var editURL: String = ""
    @State private var editKey: String = ""
    @State private var editModel: String = ""
    @State private var editTemp: Double = 0.3
    @State private var editMaxTokens: Int = 4096
    @State private var editEnabled: Bool = true
    /// Whether edit fields have unsaved changes vs original provider
    @State private var hasUnsavedEdits = false

    // ── Async state ──
    @State private var testing = false
    @State private var testResult: APITestService.TestResult?
    @State private var fetchingModels = false
    @State private var modelList: [String] = []
    @State private var modelError: String?
    @State private var deleteConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing { editView } else { displayView }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(deleteConfirming ? Color.red : (editEnabled ? Color.clear : Color.orange.opacity(0.4)), lineWidth: deleteConfirming ? 2 : 1)
        )
        .animation(.easeInOut(duration: 0.2), value: deleteConfirming)
        .onAppear { resetEditFields() }
        .onChange(of: isEditing) { _, editing in if editing { deleteConfirming = false } }
    }

    // ── Display view ──

    private var displayView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { editEnabled }, set: { v in
                    editEnabled = v; updateEnabledOnly(v)
                })) { EmptyView() }
                    .toggleStyle(.switch).controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(editName.isEmpty ? "未命名" : editName).font(.headline)
                        kindBadge(editKind)
                    }
                    HStack(spacing: 6) {
                        Text(editModel.isEmpty ? "未设置模型" : editModel)
                            .font(.caption).foregroundColor(.secondary)
                        if !editURL.isEmpty {
                            Text("·").foregroundColor(.secondary)
                            Text(editURL).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if deleteConfirming {
                        deleteConfirming = false
                    } else {
                        enterEdit()
                    }
                }

                Spacer()
                actionButtons
            }
        }
    }

    // ── Edit view ──

    private var editView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Name + enabled
            HStack {
                Toggle(isOn: $editEnabled) { EmptyView() }.toggleStyle(.switch).controlSize(.small)
                TextField("名称", text: $editName).textFieldStyle(.roundedBorder).frame(width: 150)
                    .onChange(of: editName) { markDirty() }
                Spacer()
                Button("取消") { resetEditFields(); isEditing = false }
                    .buttonStyle(.borderless).controlSize(.small)
                Button("保存") { commit(); isEditing = false }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            // Kind + Model
            HStack {
                Picker("类型", selection: $editKind) {
                    ForEach(ProviderKind.allCases) { k in Text(k.rawValue).tag(k) }
                }
                .pickerStyle(.menu).frame(width: 130)
                .onChange(of: editKind) { _, newKind in
                    markDirty()
                    if editURL.isEmpty || editURL == ProviderKind.openAI.defaultBaseURL { editURL = newKind.defaultBaseURL }
                    if editModel.isEmpty || allEnabled.contains(where: { $0.modelName == editModel }) == false { editModel = newKind.defaultModel }
                }

                TextField("模型名称", text: $editModel).textFieldStyle(.roundedBorder)
                    .onChange(of: editModel) { markDirty() }
                Button(action: fetchModels) {
                    if fetchingModels { ProgressView().scaleEffect(0.5).frame(width: 16, height: 16) }
                    else { Image(systemName: "magnifyingglass").font(.caption) }
                }
                .buttonStyle(.borderless).disabled(fetchingModels).help("获取模型列表")
            }

            // URL
            TextField("API Base URL", text: $editURL)
                .textFieldStyle(.roundedBorder).font(.caption).monospaced()
                .onChange(of: editURL) { markDirty() }

            // Key
            HStack {
                SecureField("API Key", text: $editKey).textFieldStyle(.roundedBorder)
                    .onChange(of: editKey) { markDirty() }
            }

            // Model list
            if !modelList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(modelList, id: \.self) { m in
                            Text(m)
                                .font(.caption2).padding(.horizontal, 8).padding(.vertical, 2)
                                .background(m == editModel ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                                .cornerRadius(5)
                                .onTapGesture { editModel = m; markDirty() }
                        }
                    }.padding(.horizontal, 2)
                }.frame(height: 26)
            }
            if let err = modelError { Text("⚠ \(err)").font(.caption2).foregroundColor(.orange) }

            // Temp + Tokens
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Temp:").font(.caption)
                    Slider(value: $editTemp, in: 0...2, step: 0.1).frame(width: 90)
                        .onChange(of: editTemp) { markDirty() }
                    Text(String(format: "%.1f", editTemp)).font(.caption).monospaced().frame(width: 26)
                }
                HStack(spacing: 4) {
                    Text("Tokens:").font(.caption)
                    TextField("", value: $editMaxTokens, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                        .onChange(of: editMaxTokens) { markDirty() }
                }
            }

            // Test button
            HStack {
                testButton
                if let r = testResult {
                    switch r {
                    case .success(let lat):
                        Label(String(format: "延迟 %.0fms", lat * 1000), systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(.green)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundColor(.red).lineLimit(1)
                    }
                }
            }
        }
    }

    // ── Subviews ──

    private func kindBadge(_ kind: ProviderKind) -> some View {
        Text(kind.rawValue)
            .font(.caption2).foregroundColor(.accentColor)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.1)).cornerRadius(4)
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            testButton
            if let r = testResult {
                switch r {
                case .success: Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                case .failure: Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.caption)
                }
            }
            if deleteConfirming {
                Button(action: { onDelete(provider) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                        Text("确认删除").font(.caption2)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.red)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("再次点击确认删除")
            } else {
                Button(action: {
                    deleteConfirming = true
                    // Auto-cancel after 4 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        deleteConfirming = false
                    }
                }) {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("删除")
            }

            Button(action: enterEdit) {
                Image(systemName: "pencil").font(.caption)
            }.buttonStyle(.borderless).help("编辑")
        }
    }

    private var testButton: some View {
        Group {
            if testing {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            } else {
                Button(action: testConnection) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.trianglehead.capsulepath.clockwise").font(.caption2)
                        Text("测试").font(.caption2)
                    }
                }
                .buttonStyle(.borderless).help("测试 API 连接")
            }
        }
    }

    // ── Actions ──

    private func markDirty() {
        if !hasUnsavedEdits { hasUnsavedEdits = true }
    }

    private func resetEditFields() {
        editName = provider.name
        editKind = provider.kind
        editURL = provider.baseURL
        editKey = provider.apiKey
        editModel = provider.modelName
        editTemp = provider.temperature
        editMaxTokens = provider.maxTokens
        editEnabled = provider.isEnabled
        hasUnsavedEdits = false
    }

    private func enterEdit() {
        deleteConfirming = false
        resetEditFields()
        // Lazily load API key from Keychain if not already in memory (e.g. disabled providers)
        if editKey.isEmpty, let key = onLoadKey?(provider.id), !key.isEmpty {
            editKey = key
        }
        isEditing = true
    }

    private func updateEnabledOnly(_ v: Bool) {
        var p = provider
        p.isEnabled = v
        onUpdate(p)
    }

    private func commit() {
        var p = provider
        p.name = editName
        p.kind = editKind
        p.baseURL = editURL
        p.apiKey = editKey
        p.modelName = editModel
        p.temperature = editTemp
        p.maxTokens = editMaxTokens
        p.isEnabled = editEnabled
        hasUnsavedEdits = false
        onUpdate(p)
    }

    private func testConnection() {
        testing = true; testResult = nil
        var p = provider
        p.apiKey = editKey
        // Load key lazily if not in memory
        if p.apiKey.isEmpty, let key = onLoadKey?(provider.id) {
            p.apiKey = key; editKey = key
        }
        Task {
            let r = await APITestService.testConnection(for: p)
            await MainActor.run { testResult = r; testing = false }
        }
    }

    private func fetchModels() {
        fetchingModels = true; modelList = []; modelError = nil
        var p = provider
        p.apiKey = editKey; p.baseURL = editURL
        // Load key lazily if not in memory
        if p.apiKey.isEmpty, let key = onLoadKey?(provider.id) {
            p.apiKey = key; editKey = key
        }
        Task {
            let r = await APITestService.fetchModels(for: p)
            await MainActor.run {
                fetchingModels = false
                switch r {
                case .success(let models): modelList = models
                case .failure(let err): modelError = err
                }
            }
        }
    }
}
