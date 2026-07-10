import Foundation

// MARK: - Custom Prompt Model

/// Simple single custom prompt — replaces the multi-preset system from earlier v0.4 dev.
/// Stored in UserDefaults; toggled on/off via Settings → Prompt tab.
struct CustomPrompt: Codable {
    var enabled: Bool = false
    var text: String = defaultPrompt

    static let defaultPrompt = """
You are an expert bilingual translator and localization specialist.
Translate the target text from __SOURCE_LANG__ into __TARGET_LANG__.

<Rules>
- Maintain the original tone, style, and register precisely.
- Preserve all Markdown formatting, whitespaces, and punctuation formats.
- Keep proper nouns, brand names, or code snippets unaltered unless appropriately localized.
</Rules>

[CRITICAL FORMAT CONSTRAINT]
Translate directly. Output ONLY the translated text.
No introductions, no explanations, no meta-commentary.
"""
}

