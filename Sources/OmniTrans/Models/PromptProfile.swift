import Foundation

// MARK: - Custom Prompt Model

/// Simple single custom prompt — replaces the multi-preset system from earlier v0.4 dev.
/// Stored in UserDefaults; toggled on/off via Settings → Prompt tab.
struct CustomPrompt: Codable {
    var enabled: Bool = false
    var text: String = defaultPrompt

    static let defaultPrompt = """
You are a professional, high-quality translator fluent in all languages.
Translate the provided text from __SOURCE_LANG__ into __TARGET_LANG__.

Guidelines:
- Maintain the original tone, style, and nuance.
- Match the register (formal, casual, technical) precisely.
- Do NOT add explanations or meta-commentary.
"""
}

// MARK: - Prompt Store

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var customPrompt = CustomPrompt()

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "custom_prompt"),
              let saved = try? JSONDecoder().decode(CustomPrompt.self, from: data)
        else { return }
        customPrompt = saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(customPrompt) {
            UserDefaults.standard.set(data, forKey: "custom_prompt")
        }
    }

    /// Builds the final system prompt: uses custom prompt if enabled,
    /// otherwise falls back to the built-in default.
    func buildSystemPrompt(sourceLang: String, targetLang: String, isDictionaryMode: Bool) -> String {
        let base = customPrompt.enabled ? customPrompt.text : CustomPrompt.defaultPrompt
        var prompt = base
            .replacingOccurrences(of: "__SOURCE_LANG__", with: sourceLang)
            .replacingOccurrences(of: "__TARGET_LANG__", with: targetLang)

        if isDictionaryMode {
            prompt += """


[CRITICAL FORMAT CONSTRAINT]
Respond ONLY with valid JSON. No Markdown code blocks. No explanations.
"""
        } else {
            prompt += """


[CRITICAL FORMAT CONSTRAINT]
Translate directly. No introduction, no meta-commentary.
Preserve original formatting and Markdown tags if present.
"""
        }
        return prompt
    }

    func resetToDefault() {
        customPrompt = CustomPrompt()
        save()
    }
}
