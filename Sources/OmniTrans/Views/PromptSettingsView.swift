import SwiftUI

/// Edit built-in prompt profiles: reorder, customize system prompts, select default.
struct PromptSettingsView: View {
    @ObservedObject var store = ProfileStore.shared
    @State private var editingProfileID: UUID? = nil
    @State private var editName = ""
    @State private var editPrompt = ""

    private let cardBg = Color.primary.opacity(0.04)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Default prompt selector
                VStack(alignment: .leading, spacing: 10) {
                    Label("默认预设", systemImage: "checkmark.seal")
                        .font(.headline)
                    Text("划词翻译和查词时将自动使用此预设的系统提示词")
                        .font(.caption).foregroundColor(.secondary)

                    Picker("", selection: Binding(
                        get: { store.activeProfileID },
                        set: { store.selectProfile($0) }
                    )) {
                        ForEach(store.profiles) { p in
                            HStack(spacing: 6) {
                                Image(systemName: p.iconName).frame(width: 18)
                                Text(p.name)
                            }.tag(p.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                .padding(16)
                .background(cardBg).cornerRadius(10)

                // Editable prompt list
                VStack(alignment: .leading, spacing: 10) {
                    Label("编辑预设", systemImage: "pencil.and.list.clipboard")
                        .font(.headline)
                    Text("点击编辑 → 修改名称和提示词 → 保存。使用 {sourceLang} / {targetLang} 变量自动替换语言。")
                        .font(.caption).foregroundColor(.secondary)

                    ForEach(store.profiles) { profile in
                        profileCard(profile)
                    }
                }
                .padding(16)
                .background(cardBg).cornerRadius(10)

                HStack {
                    Spacer()
                    Button(action: resetAll) {
                        Label("恢复默认预设", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func profileCard(_ profile: PromptProfile) -> some View {
        let isEditing = editingProfileID == profile.id

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: profile.iconName)
                    .foregroundColor(.accentColor).frame(width: 18)
                Text(profile.name).font(.subheadline).bold()

                if store.activeProfileID == profile.id {
                    Text("当前默认")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(3)
                }
                Spacer()
                Button(action: {
                    if isEditing {
                        saveEdit(profile)
                    } else {
                        startEditing(profile)
                    }
                }) {
                    Text(isEditing ? "保存" : "编辑")
                        .font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("预设名称", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))

                    Text("提示词（支持变量：{sourceLang} / {targetLang}）")
                        .font(.caption2).foregroundColor(.accentColor)
                    TextEditor(text: $editPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                    HStack {
                        Image(systemName: "lightbulb").font(.caption2).foregroundColor(.secondary)
                        Text("翻译方向：{sourceLang} → {targetLang}，仅输出译文")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            } else {
                Text(profile.systemPrompt)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
        .animation(.easeInOut(duration: 0.15), value: editingProfileID)
    }

    private func startEditing(_ profile: PromptProfile) {
        editingProfileID = profile.id
        editName = profile.name
        editPrompt = profile.systemPrompt
    }

    private func saveEdit(_ profile: PromptProfile) {
        guard let idx = store.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        store.profiles[idx].name = editName
        store.profiles[idx].systemPrompt = editPrompt
        store.save()
        editingProfileID = nil
    }

    private func resetAll() {
        store.profiles = PromptProfile.builtIn
        store.activeProfileID = store.profiles.first!.id
        store.save()
        editingProfileID = nil
    }
}
