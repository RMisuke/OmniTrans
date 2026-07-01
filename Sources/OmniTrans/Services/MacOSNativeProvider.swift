import Foundation
import CoreServices

/// macOS built‑in offline dictionary + translation, zero API key required.
/// - Word lookup: `DCSCopyTextDefinition` — all macOS versions
/// - Paragraph: System Translation framework (ANE) — macOS 15+
enum MacOSNativeProvider {

    // MARK: - Word lookup (all macOS versions)

    static func lookupWord(_ word: String) -> DictionaryEntry {
        let cfWord = word as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfWord))

        guard let raw = DCSCopyTextDefinition(nil, cfWord, range)?.takeRetainedValue() as String?,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return DictionaryEntry(
                word: word, isWord: false, phonetic: "",
                definitions: [.init(pos: "—", meaning: "系统词典未收录该词")],
                examples: []
            )
        }

        let definitions = parseDefinitions(from: raw)
        return DictionaryEntry(
            word: word, isWord: true, phonetic: "",
            definitions: definitions.isEmpty
                ? [.init(pos: "释义", meaning: raw.trimmingCharacters(in: .whitespacesAndNewlines))]
                : definitions,
            examples: []
        )
    }

    private static func parseDefinitions(from raw: String) -> [DictionaryEntry.Definition] {
        let lines = raw.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var results: [DictionaryEntry.Definition] = []
        for line in lines {
            if let pipeIdx = line.firstIndex(of: "|") {
                let pos = String(line[..<pipeIdx]).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                let meaning = String(line[line.index(after: pipeIdx)...]).trimmingCharacters(in: .whitespaces)
                if !pos.isEmpty, !meaning.isEmpty {
                    results.append(.init(pos: pos, meaning: meaning)); continue
                }
            }
            if let dotIdx = line.firstIndex(of: "."), line[..<dotIdx].allSatisfy({ $0.isNumber }) {
                let meaning = String(line[line.index(after: dotIdx)...]).trimmingCharacters(in: .whitespaces)
                if !meaning.isEmpty { results.append(.init(pos: "—", meaning: meaning)); continue }
            }
            if results.isEmpty || line.count < 80 {
                results.append(.init(pos: "—", meaning: line))
            }
        }
        return results
    }

    // MARK: - Paragraph translation (macOS 15+)

    /// On-device Neural Engine translation.
    /// macOS 15+: full ANE-powered offline translation via SystemTranslationEngine.
    static func translate(
        _ text: String,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage
    ) async throws -> String {
        if #available(macOS 15.0, *) {
            let target = targetLang.systemLocaleLanguage
            let source: Locale.Language? = sourceLang == .auto ? nil : sourceLang.systemLocaleLanguage
            return try await SystemTranslationEngine.shared.translateSingle(
                text, source: source, target: target
            )
        } else {
            throw TranslationService.TranslationError.apiError(
                "原生离线翻译需要 macOS 15 (Sequoia) 或更高版本。"
            )
        }
    }

    /// Streaming variant — yields incremental full-text results.
    static func translateStream(
        _ text: String,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage
    ) -> AsyncThrowingStream<String, Error> {
        guard #available(macOS 15.0, *) else {
            return AsyncThrowingStream { $0.finish(
                throwing: TranslationService.TranslationError.apiError(
                    "原生离线翻译需要 macOS 15 (Sequoia) 或更高版本。"
                )
            )}
        }
        let target = targetLang.systemLocaleLanguage
        let source: Locale.Language? = sourceLang == .auto ? nil : sourceLang.systemLocaleLanguage
        let engine = SystemTranslationEngine.shared
        return AsyncThrowingStream { continuation in
            Task {
                let inner = await engine.translateStream(text, source: source, target: target)
                do {
                    for try await chunk in inner {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
