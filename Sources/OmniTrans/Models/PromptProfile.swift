import Foundation

// MARK: - Prompt Profile Model

struct PromptProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var systemPrompt: String
    var iconName: String

    static let builtIn: [PromptProfile] = [
        PromptProfile(
            name: "默认翻译",
            systemPrompt: "You are a professional translator. Translate the following text from {sourceLang} to {targetLang} accurately and naturally. Preserve the original meaning, tone, and formatting. Output ONLY the translation without any explanations or notes.",
            iconName: "globe"
        ),
        PromptProfile(
            name: "学术论文",
            systemPrompt: "You are an academic translator specializing in scholarly papers. Translate the following text from {sourceLang} to {targetLang} using formal, precise academic language suitable for publication. Maintain technical terminology accuracy and formal register. Output ONLY the translation.",
            iconName: "graduationcap"
        ),
        PromptProfile(
            name: "口语对话",
            systemPrompt: "You are a conversational translator. Translate the following text from {sourceLang} to {targetLang} using natural, colloquial everyday language that sounds like a native speaker talking casually. Output ONLY the translation.",
            iconName: "message.fill"
        ),
        PromptProfile(
            name: "技术文档",
            systemPrompt: "You are a technical documentation translator. Translate the following text from {sourceLang} to {targetLang} preserving all technical terms, code snippets, and formatting. Use concise, precise technical language. Output ONLY the translation.",
            iconName: "chevron.left.forwardslash.chevron.right"
        ),
        PromptProfile(
            name: "文学美译",
            systemPrompt: "You are a literary translator specializing in elegant prose. Translate the following text from {sourceLang} to {targetLang} preserving the author's style, emotion, and literary quality. Use refined, expressive language appropriate for literary works. Output ONLY the translation.",
            iconName: "sparkles"
        ),
    ]
}

// MARK: - Profile Store

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profiles: [PromptProfile] = PromptProfile.builtIn
    @Published var activeProfileID: UUID

    private init() {
        activeProfileID = UUID()
        load()
    }

    var activeProfile: PromptProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    func getActivePrompt() -> String {
        return activeProfile?.systemPrompt ?? profiles.first?.systemPrompt ?? ""
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "prompt_profiles"),
              let saved = try? JSONDecoder().decode([PromptProfile].self, from: data),
              !saved.isEmpty
        else { return }
        profiles = saved
        if let savedIDStr = UserDefaults.standard.string(forKey: "active_prompt_profile_id"),
           let savedID = UUID(uuidString: savedIDStr),
           profiles.contains(where: { $0.id == savedID }) {
            activeProfileID = savedID
        } else {
            activeProfileID = UUID()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "prompt_profiles")
        }
        UserDefaults.standard.set(activeProfileID.uuidString, forKey: "active_prompt_profile_id")
    }

    func selectProfile(_ id: UUID) {
        activeProfileID = id
        save()
    }
}
