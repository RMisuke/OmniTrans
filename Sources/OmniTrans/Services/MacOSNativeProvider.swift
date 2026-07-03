import Foundation
import CoreServices

/// macOS built‑in offline dictionary, zero API key required.
/// Word lookup: `DCSCopyTextDefinition` — all macOS versions.
///
/// Paragraph translation is handled by `SystemTranslationEngine` (macOS 15+)
/// via `MacOSNativeEngineAdapter` — not this provider.
enum MacOSNativeProvider {

    // MARK: - Word lookup (all macOS versions)

    /// Look up a word in the macOS built-in dictionary.
    ///
    /// `DCSCopyTextDefinition` is a synchronous C API that can block for tens of
    /// milliseconds under disk I/O pressure.  This wrapper offloads the call to a
    /// dedicated background thread via `Task.detached` so the main run loop is never
    /// stalled, regardless of system load.
    static func lookupWord(_ word: String) async -> DictionaryEntry {
        let cfWord = word as CFString
        let length = CFStringGetLength(cfWord)
        let range = CFRange(location: 0, length: length)

        return await Task.detached(priority: .userInitiated) {
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
        }.value
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
}
