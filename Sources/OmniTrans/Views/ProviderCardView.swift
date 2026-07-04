import SwiftUI

/// API provider card with native macOS card styling.
///
/// - Uses `nativeCardStyle()` (high-opacity solid + hairline ring)
///   instead of low-opacity web-tile backgrounds.
/// - Accent actions use Action Blue (#0066cc).
struct ProviderCardView: View {
    let provider: APIProvider
    let allEnabled: [APIProvider]
    let onUpdate: (APIProvider) -> Void
    let onDelete: (APIProvider) -> Void
    let onLoadKey: ((UUID) -> String)?

    @State private var isEditing = false
    @State private var editName: String = ""
    @State private var editKind: ProviderKind = .openAI
    @State private var editURL: String = ""
    @State private var editKey: String = ""
    @State private var editModel: String = ""
    @State private var editTemp: Double = 0.3
    @State private var editMaxTokens: Int = 4096
    @State private var editEnabled: Bool = true
    @State private var editSecret: String = ""
    @State private var editRegion: String = ""
    @State private var hasUnsavedEdits = false
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
        .padding(.horizontal, AppTheme.spaceSM).padding(.vertical, 8)
        .nativeCardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radiusLG)
                .stroke(deleteConfirming ? AppTheme.error : (editEnabled ? Color.clear : AppTheme.warning.opacity(0.4)), lineWidth: deleteConfirming ? 2 : 1)
        )
        .animation(AppTheme.Motion.snip.gated, value: deleteConfirming)
        .onAppear { resetEditFields() }
        .onChange(of: isEditing) { _, editing in if editing { deleteConfirming = false } }
    }

    private var displayView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { editEnabled }, set: { v in editEnabled = v; updateEnabledOnly(v) })) { EmptyView() }
                    .toggleStyle(.switch).controlSize(.small).tint(AppTheme.toggleTint)
                    .disabled(provider.kind == .macOSNative)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(editName.isEmpty ? "未命名" : editName).font(.headline).foregroundColor(AppTheme.textPrimary)
                        kindBadge(editKind)
                    }
                    HStack(spacing: 6) {
                        Text(editModel.isEmpty ? "未设置模型" : editModel).font(.caption).foregroundColor(AppTheme.textSecondary)
                        if !editURL.isEmpty {
                            Text("·").foregroundColor(AppTheme.textSecondary)
                            Text(editURL).font(.caption2).foregroundColor(AppTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if provider.isBuiltIn { return }; deleteConfirming ? (deleteConfirming = false) : enterEdit() }
                Spacer(); actionButtons
            }
        }
    }

    private var editView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $editEnabled) { EmptyView() }.toggleStyle(.switch).controlSize(.small).tint(AppTheme.toggleTint).disabled(provider.kind == .macOSNative)
                TextField("名称", text: $editName).textFieldStyle(.roundedBorder).frame(width: 150).onChange(of: editName) { markDirty() }
                Spacer()
                Button("取消") { resetEditFields(); isEditing = false }.buttonStyle(.borderless).controlSize(.small)
                Button("保存") { commit(); isEditing = false }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(AppTheme.accentAction)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            HStack {
                Picker("类型", selection: $editKind) {
                    ForEach(ProviderKind.allCases) { k in Text(k.rawValue).tag(k) }
                }.pickerStyle(.menu).frame(width: 130).onChange(of: editKind) { _, nk in markDirty(); if editURL.isEmpty || editURL == ProviderKind.openAI.defaultBaseURL { editURL = nk.defaultBaseURL }; if editModel.isEmpty || allEnabled.contains(where: { $0.modelName == editModel }) == false { editModel = nk.defaultModel } }
                TextField("模型", text: $editModel).textFieldStyle(.roundedBorder).onChange(of: editModel) { markDirty() }
            }
            TextField("Base URL", text: $editURL).textFieldStyle(.roundedBorder).onChange(of: editURL) { markDirty() }
            HStack(spacing: 6) {
                Text(keyLabel).font(.caption).foregroundColor(AppTheme.textSecondary).frame(width: 70, alignment: .leading)
                SecureField(keyPlaceholder, text: $editKey).textFieldStyle(.roundedBorder).onChange(of: editKey) { markDirty() }
            }
            if editKind.isTraditionalMT {
                if editKind == .alibabaMT || editKind == .volcengineMT || editKind == .bingMT {
                    HStack(spacing: 6) {
                        Text(secretLabel).font(.caption).foregroundColor(AppTheme.textSecondary).frame(width: 70, alignment: .leading)
                        SecureField(secretPlaceholder, text: $editSecret).textFieldStyle(.roundedBorder).onChange(of: editSecret) { markDirty() }
                    }
                }
                if editKind == .bingMT {
                    HStack(spacing: 6) {
                        Text("Region").font(.caption).foregroundColor(AppTheme.textSecondary).frame(width: 70, alignment: .leading)
                        TextField("e.g. eastasia", text: $editRegion).textFieldStyle(.roundedBorder).onChange(of: editRegion) { markDirty() }
                    }
                }
            }
            if !editKind.isTraditionalMT {
                HStack { Text("Temperature").font(.caption).foregroundColor(AppTheme.textSecondary); Slider(value: $editTemp, in: 0...2, step: 0.1) { _ in markDirty() }; Text(String(format: "%.1f", editTemp)).font(.caption).monospacedDigit().frame(width: 30) }
                HStack { Text("Max Tokens").font(.caption).foregroundColor(AppTheme.textSecondary); TextField("", value: $editMaxTokens, format: .number).textFieldStyle(.roundedBorder).frame(width: 80).onChange(of: editMaxTokens) { markDirty() }; Spacer() }
                HStack {
                    Button(action: fetchModels) { HStack(spacing: 4) { if fetchingModels { ProgressView().scaleEffect(0.5).frame(width: 12, height: 12) } else { Image(systemName: "list.bullet.rectangle") }; Text("拉取模型列表").font(.caption) } }.buttonStyle(.borderless).disabled(fetchingModels); Spacer()
                }
                if !modelList.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("可用模型").font(.caption).foregroundColor(AppTheme.textSecondary)
                        ForEach(modelList, id: \.self) { m in
                            HStack { Text(m).font(.caption).foregroundColor(m == editModel ? AppTheme.accentAction : AppTheme.textPrimary); if m == editModel { Image(systemName: "checkmark").font(.caption2).foregroundColor(AppTheme.accentAction) }; Spacer() }
                                .padding(.horizontal, 6).padding(.vertical, 2).background(m == editModel ? AppTheme.accentAction.opacity(0.1) : Color.clear).cornerRadius(4).contentShape(Rectangle()).onTapGesture { editModel = m; markDirty() }
                        }
                    }
                }
                if let modelError { Text(modelError).font(.caption).foregroundColor(AppTheme.error) }
            }
        }
    }

    private func kindBadge(_ kind: ProviderKind) -> some View {
        Text(kind.rawValue).font(.caption2).foregroundColor(AppTheme.accentAction).padding(.horizontal, 6).padding(.vertical, 1).background(AppTheme.accentAction.opacity(0.1)).cornerRadius(4)
    }
    private var keyLabel: String { switch editKind { case .alibabaMT, .volcengineMT: "Key ID"; case .bingMT: "Key"; default: "API Key" } }
    private var keyPlaceholder: String { switch editKind { case .alibabaMT, .volcengineMT: "Access Key"; default: "sk-..." } }
    private var secretLabel: String { switch editKind { case .alibabaMT, .volcengineMT: "Secret"; case .bingMT: "Secret"; default: "Secret" } }
    private var secretPlaceholder: String { switch editKind { case .alibabaMT, .volcengineMT: "Secret Key"; case .bingMT: "API Secret"; default: "..." } }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            testButton
            if let r = testResult {
                switch r { case .success: Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.success).font(.caption); case .failure: Image(systemName: "xmark.circle.fill").foregroundColor(AppTheme.error).font(.caption) }
            }
            if deleteConfirming {
                Button(action: { onDelete(provider) }) { HStack(spacing: 4) { Image(systemName: "trash.fill"); Text("确认删除").font(.caption2) }.foregroundColor(.white).padding(.horizontal, 8).padding(.vertical, 3).background(AppTheme.error).cornerRadius(5) }.buttonStyle(.plain).help("再次点击确认删除")
            } else if !provider.isBuiltIn {
                Button(action: { deleteConfirming = true; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { deleteConfirming = false } }) { Image(systemName: "trash").foregroundColor(AppTheme.error) }.buttonStyle(.borderless).help("删除")
            }
            if !provider.isBuiltIn { Button(action: enterEdit) { Image(systemName: "pencil").font(.caption) }.buttonStyle(.borderless).help("编辑") }
        }
    }
    private var testButton: some View {
        Group { if testing { ProgressView().scaleEffect(0.5).frame(width: 16, height: 16) } else { Button(action: testConnection) { HStack(spacing: 2) { Image(systemName: "arrow.trianglehead.capsulepath.clockwise").font(.caption2); Text("测试").font(.caption2) } }.buttonStyle(.borderless).help("测试 API 连接") } }
    }

    private func markDirty() { if !hasUnsavedEdits { hasUnsavedEdits = true } }
    private func resetEditFields() {
        editName = provider.name; editKind = provider.kind; editURL = provider.baseURL; editKey = provider.apiKey
        editModel = provider.modelName; editTemp = provider.temperature; editMaxTokens = provider.maxTokens
        editEnabled = provider.isEnabled; editSecret = provider.apiSecret; editRegion = provider.customRegion; hasUnsavedEdits = false
    }
    private func enterEdit() {
        deleteConfirming = false; resetEditFields()
        let fields = ProviderStorageManager.cachedFields(for: provider.id)
        if editKey.isEmpty, !fields.apiKey.isEmpty { editKey = fields.apiKey }
        if editSecret.isEmpty, !fields.apiSecret.isEmpty { editSecret = fields.apiSecret }
        if editRegion.isEmpty, !fields.customRegion.isEmpty { editRegion = fields.customRegion }
        isEditing = true
    }
    private func updateEnabledOnly(_ v: Bool) { var p = provider; p.isEnabled = v; onUpdate(p) }
    private func commit() {
        var p = provider
        p.name = editName; p.kind = editKind; p.baseURL = editURL; p.apiKey = editKey; p.modelName = editModel
        p.temperature = editTemp; p.maxTokens = editMaxTokens; p.isEnabled = editEnabled
        p.apiSecret = editSecret; p.customRegion = editRegion; hasUnsavedEdits = false
        let kf = KeychainFields(apiKey: editKey, apiSecret: editSecret, customRegion: editRegion)
        if !kf.isEmpty { KeychainManager.saveFields(kf, for: p.id) }
        onUpdate(p)
    }
    private func testConnection() {
        testing = true; testResult = nil; var p = provider; p.apiKey = editKey
        if p.apiKey.isEmpty, let key = onLoadKey?(provider.id) { p.apiKey = key; editKey = key }
        Task { let r = await APITestService.testConnection(for: p); await MainActor.run { testResult = r; testing = false } }
    }
    private func fetchModels() {
        fetchingModels = true; modelList = []; modelError = nil; var p = provider; p.apiKey = editKey; p.baseURL = editURL
        if p.apiKey.isEmpty, let key = onLoadKey?(provider.id) { p.apiKey = key; editKey = key }
        Task { let r = await APITestService.fetchModels(for: p); await MainActor.run { fetchingModels = false; switch r { case .success(let models): modelList = models; case .failure(let err): modelError = err } } }
    }
}
