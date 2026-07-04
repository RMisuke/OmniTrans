import Foundation

/// Structured dictionary lookup result — unified schema for both AI/LLM and
/// macOS native dictionary (`DCSCopyTextDefinition`) data sources.
///
/// All optional fields are populated only when the source data provides them;
/// empty strings and placeholder values are never emitted.
struct DictionaryEntry: Codable, Equatable {
    let isWord: Bool
    let word: String
    let phonetic: String
    /// BrE / AmE variants when available from native dictionary.
    let phoneticVariants: [PhoneticVariant]?
    let definitions: [Definition]
    let examples: [Example]
    let inflections: [Inflection]

    struct PhoneticVariant: Codable, Equatable {
        let type: String  // "BrE" or "AmE"
        let value: String
    }

    struct Definition: Codable, Equatable, Identifiable {
        var id: String { "\(pos)_\(senseNumber ?? 0)_\(meaning.prefix(20))" }
        let pos: String
        /// Full POS label (e.g. "intransitive verb") — native dictionary only.
        let posLabel: String?
        /// Sense number (1, 2, 3…) — native dictionary only.
        let senseNumber: Int?
        /// Domain / register labels (e.g. ["Computer", "formal"]).
        let labels: [String]?
        let meaning: String
    }

    struct Example: Codable, Equatable, Identifiable {
        var id: String { en + zh }
        let en: String
        let zh: String
    }

    struct Inflection: Codable, Equatable, Identifiable {
        var id: String { form }
        let form: String
        let label: String
    }

    var isEmpty: Bool { !isWord && definitions.isEmpty && examples.isEmpty }

    static func empty(for word: String) -> DictionaryEntry {
        DictionaryEntry(isWord: false, word: word, phonetic: "",
            phoneticVariants: nil, definitions: [], examples: [], inflections: [])
    }

    // MARK: - Robust LLM JSON parsing

    static func parse(from jsonString: String, word: String) -> DictionaryEntry? {
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[DictParse] raw length: \(cleaned.count), preview: \(String(cleaned.prefix(120)))")

        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let braceOpen = cleaned.firstIndex(of: "{"),
           let braceClose = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[braceOpen...braceClose])
        }

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

        let decoder = JSONDecoder()
        do {
            let raw = try decoder.decode(RawDict.self, from: data)
            let entry = DictionaryEntry(
                isWord: raw.isWord ?? true, word: word,
                phonetic: raw.phonetic ?? "",
                phoneticVariants: raw.phoneticVariants,
                definitions: raw.definitions ?? [],
                examples: raw.examples ?? [],
                inflections: raw.inflections ?? []
            )
            print("[DictParse] ✅ parsed: \(entry.definitions.count) defs, \(entry.examples.count) exs")
            return entry
        } catch {
            print("[DictParse] ❌ decode error: \(error)")
            return nil
        }
    }
}

/// Intermediate decodable for LLM JSON output (no `word` field).
private struct RawDict: Codable {
    let isWord: Bool?
    let phonetic: String?
    let phoneticVariants: [DictionaryEntry.PhoneticVariant]?
    let definitions: [DictionaryEntry.Definition]?
    let examples: [DictionaryEntry.Example]?
    let inflections: [DictionaryEntry.Inflection]?
}

/// Detects whether a query string is a single‑word lookup.
enum WordDetector {
    static func isWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 30,
              !trimmed.contains(" "), !trimmed.contains("\n"),
              trimmed.rangeOfCharacter(from: .letters) != nil
        else { return false }
        return true
    }
}
