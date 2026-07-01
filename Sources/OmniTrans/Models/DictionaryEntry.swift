import Foundation

/// Structured dictionary lookup result — decoded from JSON Mode LLM output.
struct DictionaryEntry: Codable, Equatable {
    let word: String
    let isWord: Bool
    let phonetic: String
    let definitions: [Definition]
    let examples: [Example]

    struct Definition: Codable, Equatable, Identifiable {
        var id: String { pos + meaning }
        let pos: String
        let meaning: String
    }

    struct Example: Codable, Equatable, Identifiable {
        var id: String { en + zh }
        let en: String
        let zh: String
    }

    var isEmpty: Bool { !isWord && definitions.isEmpty && examples.isEmpty }

    static func empty(for word: String) -> DictionaryEntry {
        DictionaryEntry(word: word, isWord: false, phonetic: "", definitions: [], examples: [])
    }

    // MARK: - Robust parsing

    static func parse(from jsonString: String, word: String) -> DictionaryEntry? {
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        print("[DictParse] raw length: \(cleaned.count), preview: \(String(cleaned.prefix(120)))")

        // Strategy 1: Strip markdown fences
        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strategy 2: Extract JSON object — find first { and last }
        if let braceOpen = cleaned.firstIndex(of: "{"),
           let braceClose = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[braceOpen...braceClose])
        }

        // Strategy 3: Fix common LLM JSON mistakes
        let sanitized = cleaned
            .replacingOccurrences(of: ",\n]", with: "\n]")
            .replacingOccurrences(of: ",\n}", with: "\n}")
            .replacingOccurrences(of: ", ]", with: "]")
            .replacingOccurrences(of: ", }", with: "}")
            .replacingOccurrences(of: "\\'", with: "'")

        guard let data = sanitized.data(using: .utf8) else {
            print("[DictParse] ❌ utf8 encoding failed")
            return nil
        }

        // Decode WITHOUT word field first (LLM doesn't include it)
        let decoder = JSONDecoder()
        do {
            let raw = try decoder.decode(RawDict.self, from: data)
            let entry = DictionaryEntry(
                word: word,
                isWord: raw.isWord ?? true,
                phonetic: raw.phonetic ?? "",
                definitions: raw.definitions ?? [],
                examples: raw.examples ?? []
            )
            print("[DictParse] ✅ parsed: \(entry.definitions.count) defs, \(entry.examples.count) exs")
            return entry
        } catch {
            print("[DictParse] ❌ decode error: \(error)")
            return nil
        }
    }
}

/// Intermediate decodable that matches LLM output (no `word` field).
private struct RawDict: Codable {
    let isWord: Bool?
    let phonetic: String?
    let definitions: [DictionaryEntry.Definition]?
    let examples: [DictionaryEntry.Example]?
}

/// Detects whether a query string is a single‑word lookup.
enum WordDetector {
    static func isWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count < 30,
              !trimmed.contains(" "),
              !trimmed.contains("\n"),
              trimmed.rangeOfCharacter(from: .letters) != nil
        else { return false }
        return true
    }
}
