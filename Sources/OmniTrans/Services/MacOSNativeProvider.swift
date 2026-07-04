import Foundation
import CoreServices

/// macOS built‑in offline dictionary, zero API key required.
/// Word lookup delegates to `NativeDictionaryParser` which produces
/// structured `DictionaryEntry` output matching the AI/LLM JSON schema.
enum MacOSNativeProvider {

    nonisolated(unsafe) private static let cache: NSCache<NSString, DictEntryBox> = {
        let c = NSCache<NSString, DictEntryBox>()
        c.countLimit = 200
        return c
    }()

    /// Pre-warms the cache with common lookup words to reduce first-query latency.
    /// Call from `applicationDidFinishLaunching` on a background queue.
    static func prewarmCache() {
        let commonWords = ["hello", "world", "the", "and", "that", "have", "for", "not", "with", "you"]
        DispatchQueue.global(qos: .utility).async {
            for word in commonWords {
                let cfWord = word as CFString
                let range = CFRange(location: 0, length: CFStringGetLength(cfWord))
                if let raw = DCSCopyTextDefinition(nil, cfWord, range)?.takeRetainedValue() as String?,
                   !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let parsed = NativeDictionaryParser.parse(word: word, rawText: stripHTML(raw)) {
                    cache.setObject(DictEntryBox(parsed), forKey: word.lowercased() as NSString)
                }
            }
        }
    }

    private final class DictEntryBox {
        let entry: DictionaryEntry
        init(_ entry: DictionaryEntry) { self.entry = entry }
    }

    static func lookupWord(_ word: String) async -> DictionaryEntry {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() as NSString

        if let box = cache.object(forKey: key) { return box.entry }

        let cfWord = word as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfWord))

        return await Task.detached(priority: .userInitiated) { [key] in
            guard let raw = DCSCopyTextDefinition(nil, cfWord, range)?.takeRetainedValue() as String?,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                let missing = DictionaryEntry(isWord: false, word: word, phonetic: "",
                    phoneticVariants: nil,
                    definitions: [.init(pos: "—", posLabel: nil, senseNumber: nil, labels: nil, meaning: "系统词典未收录该词")],
                    examples: [], inflections: [])
                MacOSNativeProvider.cache.setObject(DictEntryBox(missing), forKey: key)
                return missing
            }

            // NativeDictionaryParser.preprocess handles HTML stripping internally
            if let parsed = NativeDictionaryParser.parse(word: word, rawText: raw) {
                MacOSNativeProvider.cache.setObject(DictEntryBox(parsed), forKey: key)
                return parsed
            }
            let fallback = DictionaryEntry(isWord: true, word: word, phonetic: "",
                phoneticVariants: nil,
                definitions: [.init(pos: "释义", posLabel: nil, senseNumber: nil, labels: nil,
                                    meaning: raw.trimmingCharacters(in: .whitespacesAndNewlines))],
                examples: [], inflections: [])
            MacOSNativeProvider.cache.setObject(DictEntryBox(fallback), forKey: key)
            return fallback
        }.value
    }

    private static func stripHTML(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8) else { return raw }
        if let attr = try? NSAttributedString(data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil) {
            return attr.string
        }
        return raw
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: "&")
            .replacingOccurrences(of: "<",  with: "<")
            .replacingOccurrences(of: ">",  with: ">")
    }
}
