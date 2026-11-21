import Foundation
import OSLog

/// M8: 词典解析日志统一走 OSLog（subsystem 统一），避免 print 噪音。
private let dictParseLog = OSLog(subsystem: AppLogging.subsystem, category: "DictParse")

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

    /// 词条纯文本（复制/朗读用）：单词 + 音标 + 释义 + 例句，
    /// 而非只有 word（P1-A D8）。
    var plainText: String {
        var lines: [String] = [word]
        if !phonetic.isEmpty { lines.append(phonetic) }
        for def in definitions {
            let pos = def.pos == "—" ? "" : "[\(def.pos)] "
            lines.append("\(pos)\(def.meaning)")
        }
        for ex in examples {
            lines.append(ex.zh.isEmpty ? ex.en : "\(ex.en) — \(ex.zh)")
        }
        return lines.joined(separator: "\n")
    }

    static func empty(for word: String) -> DictionaryEntry {
        DictionaryEntry(isWord: false, word: word, phonetic: "",
            phoneticVariants: nil, definitions: [], examples: [], inflections: [])
    }

    // MARK: - Robust LLM JSON parsing

    static func parse(from jsonString: String, word: String) -> DictionaryEntry? {
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        os_log(.debug, log: dictParseLog, "raw length: %d, preview: %{public}@", cleaned.count, String(cleaned.prefix(120)))

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
            os_log(.error, log: dictParseLog, "utf8 encoding failed")
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
            os_log(.debug, log: dictParseLog, "parsed: %d defs, %d exs", entry.definitions.count, entry.examples.count)
            return entry
        } catch {
            os_log(.error, log: dictParseLog, "decode error: %{public}@", String(describing: error))
            return nil
        }
    }
}

/// Intermediate decodable for LLM JSON output (no `word` field).
/// 兼容 `is_word` / `isWord` 与 snake/camel 两种音标字段键名（P1-A：
/// prompt 输出 `is_word`，旧解码只认 `isWord`，字段永为 nil 靠 ?? true 掩盖）。
private struct RawDict: Decodable {
    let isWord: Bool?
    let phonetic: String?
    let phoneticVariants: [DictionaryEntry.PhoneticVariant]?
    let definitions: [DictionaryEntry.Definition]?
    let examples: [DictionaryEntry.Example]?
    let inflections: [DictionaryEntry.Inflection]?

    private enum CodingKeys: String, CodingKey {
        case isWord, is_word, phonetic, definitions, examples, inflections
        case phoneticVariants, phonetic_variants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // prompt 输出 is_word；兼容旧 camelCase
        if let w = try c.decodeIfPresent(Bool.self, forKey: .is_word) {
            isWord = w
        } else {
            isWord = try c.decodeIfPresent(Bool.self, forKey: .isWord)
        }
        phonetic = try c.decodeIfPresent(String.self, forKey: .phonetic)
        if let v = try c.decodeIfPresent([DictionaryEntry.PhoneticVariant].self, forKey: .phoneticVariants) {
            phoneticVariants = v
        } else {
            phoneticVariants = try c.decodeIfPresent([DictionaryEntry.PhoneticVariant].self, forKey: .phonetic_variants)
        }
        definitions = try c.decodeIfPresent([DictionaryEntry.Definition].self, forKey: .definitions)
        examples = try c.decodeIfPresent([DictionaryEntry.Example].self, forKey: .examples)
        inflections = try c.decodeIfPresent([DictionaryEntry.Inflection].self, forKey: .inflections)
    }
}

/// Detects whether a query string is a single‑word lookup.
enum WordDetector {
    /// 判断查询是否适合词典查词（P0-G2 重写）。
    /// 旧规则仅「≤50 字符 + 含字母」：不检查空格（how are you 判词）、
    /// 中文整句判词、内部标点不检查。新规则：
    /// 1. 内部空格 → 句；2. 首尾标点剥离；3. 内部断句标点 → 句；
    /// 4. 数字主导 → 非词；5. CJK+拉丁混合 → 句；6. 纯 CJK ≤4 字 → 词；
    /// 7. 拉丁 ≤30 字符且仅含字母/数字/复合字符（- . '）。
    static func isWord(_ text: String) -> Bool {
        // 归一化（P1-3）：NFD 组合字符（café）、弯引号（don’t）统一，
        // 否则组合符落入 other、弯引号落入断句符导致误判为句。
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        guard !normalized.isEmpty, !normalized.contains("\n") else { return false }

        // 1. 内部空格 → 短语/句子（state-of-the-art 等复合词无空格，不受影响）
        if normalized.contains(where: { $0.isWhitespace }) { return false }

        // 2. 剥离首尾标点（hello, / "wait!" / Dr. / 你好。）
        let edgePunct = CharacterSet(charactersIn: ".,!?;:'\"()[]。，、！？；：…")
        let core = normalized.trimmingCharacters(in: edgePunct)
        guard !core.isEmpty else { return false }

        // 3. 内部断句标点 → 句（wait—what / and/or / 你好，世界）
        let breakers = CharacterSet(charactersIn: "—–/,;:!?\"()[]，、；：！？…")
        if core.rangeOfCharacter(from: breakers) != nil { return false }

        var cjk = 0, latin = 0, digit = 0, other = 0
        for scalar in core.unicodeScalars {
            let v = scalar.value
            if Self.isCJKIdeograph(v) || Self.isKanaOrHangul(v) {
                cjk += 1
            } else if CharacterSet.letters.contains(scalar) {
                latin += 1
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digit += 1
            } else if scalar == "-" || scalar == "." || scalar == "'" {
                // 复合词允许字符（state-of-the-art / Dr. / don't）
            } else {
                other += 1
            }
        }
        guard other == 0 else { return false }

        // 4. 数字主导 → 非词（12345 / 3.14）
        if digit > latin + cjk { return false }
        // 5. CJK + 拉丁混合 → 句（用AI翻译）
        if cjk > 0 && latin > 0 { return false }
        // 6. 纯 CJK：词语/成语 ≤4 字，更长 → 句
        if cjk > 0 { return core.count <= 4 }
        // 7. 拉丁：≤30 字符且含字母
        return latin > 0 && core.count <= 30
    }

    /// CJK 表意文字（含扩展 A/B/C/D/E/F/G/兼容区）（P1-3）。
    private static func isCJKIdeograph(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v)      // 基本区
            || (0x3400...0x4DBF).contains(v)   // 扩展 A
            || (0x20000...0x2A6DF).contains(v) // 扩展 B
            || (0x2A700...0x2EBEF).contains(v) // 扩展 C-F
            || (0x30000...0x3134F).contains(v) // 扩展 G
            || (0xF900...0xFAFF).contains(v)   // 兼容表意
    }

    /// 日文假名 / 韩文音节（按 CJK 计入）。
    private static func isKanaOrHangul(_ v: UInt32) -> Bool {
        (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
    }
}

/// Detects whether a query string is a single‑word lookup.
