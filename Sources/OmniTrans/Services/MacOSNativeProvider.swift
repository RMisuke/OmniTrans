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

    private final class DictEntryBox {
        let entry: DictionaryEntry
        init(_ entry: DictionaryEntry) { self.entry = entry }
    }

    static func lookupWord(_ word: String) async -> DictionaryEntry {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines) as NSString

        if let box = cache.object(forKey: key) { return box.entry }

        let cfWord = word as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfWord))

        return await Task.detached(priority: .userInitiated) { [key] in
            guard let raw = DCSCopyTextDefinition(nil, cfWord, range)?.takeRetainedValue() as String?,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                let missing = DictionaryEntry(isWord: false, word: word, phonetic: "",
                    phoneticVariants: nil,
                    definitions: [.init(pos: "—", posLabel: nil, senseNumber: nil, labels: nil, meaning: "系统词典未收录该词，可切换 AI 引擎查询")],
                    examples: [], inflections: [])
                // 未收录不缓存：避免本会话内永不重查（P0-R2）
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
}
