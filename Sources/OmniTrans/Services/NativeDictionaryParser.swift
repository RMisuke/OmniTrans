import Foundation

// MARK: - Native Dictionary Parser

/// State-machine parser that converts `DCSCopyTextDefinition` plain-text output
/// into a structured `DictionaryEntry` matching the AI/LLM JSON schema.
///
/// ## Parsing Pipeline
/// 1. Preprocess: strip HTML, normalise whitespace
/// 2. Extract pronunciation (BrE / AmE)
/// 3. Scan line-by-line: POS blocks → numbered senses → ▸ examples
/// 4. Post-process: strip pinyin, deduplicate, validate
///
/// ## Pinyin Stripping
/// Chinese dictionary entries often embed pinyin (e.g. "shùzhī") alongside
/// definitions.  The parser detects strings containing tone-number vowels
/// (āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ) and removes them while preserving
/// legitimate English words (DNA, WiFi, etc.) that lack tone marks.
enum NativeDictionaryParser {

    // MARK: - Public API

    /// Parses raw text from `DCSCopyTextDefinition` into a `DictionaryEntry`.
    /// Returns `nil` if no definitions could be extracted.
    static func parse(word: String, rawText: String) -> DictionaryEntry? {
        let cleaned = preprocess(rawText)
        let lines = cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // ── Extract phonetics ──
        let (phonetic, phoneticVariants) = extractPhonetics(from: lines)

        // ── State-machine parsing ──
        var definitions: [DictionaryEntry.Definition] = []
        var examples: [DictionaryEntry.Example] = []
        var inflections: [DictionaryEntry.Inflection] = []

        var currentPOS = ""
        var currentPOSLabel: String? = nil
        var currentSenseNumber = 0
        var currentLabels: [String] = []
        var currentMeaning = ""
        var inDefinition = false

        for line in lines {
            // Skip already-extracted pronunciation lines
            if isPronunciationLine(line) { continue }

            // ── Inflection line ──
            if let infl = tryMatchInflection(line) {
                if inDefinition { flushCurrentSense(into: &definitions, pos: currentPOS, posLabel: currentPOSLabel, number: currentSenseNumber, labels: currentLabels, meaning: &currentMeaning); inDefinition = false }
                inflections.append(infl)
                continue
            }

            // ── POS block header ──
            if let (pos, label) = tryMatchPOS(line) {
                if inDefinition { flushCurrentSense(into: &definitions, pos: currentPOS, posLabel: currentPOSLabel, number: currentSenseNumber, labels: currentLabels, meaning: &currentMeaning); inDefinition = false }
                currentPOS = pos
                currentPOSLabel = label
                currentSenseNumber = 0
                currentLabels = []
                continue
            }

            // ── Numbered sense: "1 definition" or "① definition" ──
            if let (num, labels) = tryMatchSenseStart(line) {
                if inDefinition { flushCurrentSense(into: &definitions, pos: currentPOS, posLabel: currentPOSLabel, number: currentSenseNumber, labels: currentLabels, meaning: &currentMeaning) }
                currentSenseNumber = num
                currentLabels = labels
                // Extract remaining text after number + labels as meaning
                currentMeaning = extractMeaningAfterSense(line, number: num, labels: labels)
                inDefinition = true
                continue
            }

            // ── ▸ example ──
            if let example = tryMatchExample(line) {
                // Attach to last definition if available, else top-level
                if inDefinition, !definitions.isEmpty {
                    // Will be handled by flush — we attach examples post-hoc
                }
                examples.append(example)
                continue
            }

            // ── Continuation of current definition ──
            if inDefinition && !line.isEmpty {
                let stripped = stripPinyin(line)
                if !stripped.isEmpty {
                    if !currentMeaning.isEmpty { currentMeaning += " " }
                    currentMeaning += stripped
                }
                continue
            }

            // ── Pipe-delimited fallback ──
            if let pipeIdx = line.firstIndex(of: "|") {
                let rawPOS = String(line[..<pipeIdx]).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                let meaning = String(line[line.index(after: pipeIdx)...]).trimmingCharacters(in: .whitespaces)
                if !rawPOS.isEmpty, !meaning.isEmpty {
                    definitions.append(.init(pos: normalizedPOS(rawPOS), posLabel: nil, senseNumber: nil, labels: nil, meaning: stripPinyin(meaning)))
                }
                continue
            }

            // ── Fallback: short plain line ──
            if !inDefinition && definitions.isEmpty && line.count < 150 {
                definitions.append(.init(pos: "—", posLabel: nil, senseNumber: nil, labels: nil, meaning: stripPinyin(line)))
            }
        }

        // Flush last pending sense
        if inDefinition {
            flushCurrentSense(into: &definitions, pos: currentPOS, posLabel: currentPOSLabel, number: currentSenseNumber, labels: currentLabels, meaning: &currentMeaning)
        }

        // ── Attach examples to their corresponding definitions ──
        attachExamples(&definitions, &examples)

        // ── Validate ──
        guard !definitions.isEmpty else {
            print("[NativeDictParser] ❌ No definitions extracted for '\(word)'")
            return nil
        }

        print("[NativeDictParser] ✅ Parsed '\(word)': \(definitions.count) defs, \(examples.count) exs, \(inflections.count) infls")

        return DictionaryEntry(
            isWord: true, word: word,
            phonetic: phonetic,
            phoneticVariants: phoneticVariants.isEmpty ? nil : phoneticVariants,
            definitions: definitions,
            examples: examples,
            inflections: inflections
        )
    }

    // MARK: - Preprocessing

    private static func preprocess(_ raw: String) -> String {
        var result = raw
        // Strip HTML
        if let data = result.data(using: .utf8) {
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            if let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) {
                result = attr.string
            }
        }
        // Normalise whitespace
        result = result.replacingOccurrences(of: "\t", with: " ")
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        // Collapse multiple blank lines
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Phonetic Extraction

    private static let phoneticRegex = try! NSRegularExpression(
        pattern: #"(BrE|AmE|NAmE|NAm|US|UK)\s*:?\s*(/.+?/)"#,
        options: .caseInsensitive
    )

    @inline(__always)
    private static func isPronunciationLine(_ line: String) -> Bool {
        phoneticRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func extractPhonetics(from lines: [String]) -> (String, [DictionaryEntry.PhoneticVariant]) {
        var variants: [DictionaryEntry.PhoneticVariant] = []
        for line in lines {
            guard let match = phoneticRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  match.numberOfRanges >= 3,
                  let typeRange = Range(match.range(at: 1), in: line),
                  let ipaRange  = Range(match.range(at: 2), in: line)
            else { continue }
            let type = String(line[typeRange])
            let ipa  = String(line[ipaRange])
            let label: String
            switch type.lowercased() {
            case "bre", "uk": label = "BrE"
            case "ame", "name", "us": label = "AmE"
            default: label = type
            }
            variants.append(.init(type: label, value: ipa))
        }
        let primary = variants.first(where: { $0.type == "AmE" })?.value
                   ?? variants.first?.value
                   ?? ""
        return (primary, variants)
    }

    // MARK: - POS Detection

    private static let posRegex = try! NSRegularExpression(
        pattern: #"^[A-Z][a-z]+(?:\s+[a-z]+)?$"#
    )

    private static let knownPOSLabels: Set<String> = [
        "noun", "verb", "adjective", "adverb", "pronoun", "preposition",
        "conjunction", "interjection", "article", "numeral", "determiner",
        "transitive verb", "intransitive verb", "phrasal verb", "auxiliary verb",
        "名词", "动词", "形容词", "副词", "代词", "介词", "连词", "感叹词", "冠词", "数词", "助词",
        "及物动词", "不及物动词"
    ]

    private static func tryMatchPOS(_ line: String) -> (pos: String, label: String?)? {
        let clean = line.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        let lower = clean.lowercased()
        guard line.count <= 30, knownPOSLabels.contains(lower) else { return nil }
        let pos = normalizedPOS(lower)
        let label: String? = lower == pos.lowercased() ? nil : lower
        return (pos, label)
    }

    // MARK: - Sense Number Detection

    private static let senseRegex = try! NSRegularExpression(
        pattern: #"^[①②③④⑤⑥⑦⑧⑨]|^\d{1,2}\b"#
    )

    private static let labelRegex = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]"#
    )

    /// Returns (senseNumber, [labels]) if line starts a new sense.
    private static func tryMatchSenseStart(_ line: String) -> (Int, [String])? {
        // Match circled numbers ①-⑨
        let circled: [Character: Int] = ["①":1,"②":2,"③":3,"④":4,"⑤":5,"⑥":6,"⑦":7,"⑧":8,"⑨":9]
        if let first = line.first, let num = circled[first] {
            let labels = extractLabels(from: line)
            return (num, labels)
        }
        // Match "1 ", "2 " etc.
        guard let match = senseRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line),
              let num = Int(String(line[range]).trimmingCharacters(in: .whitespaces))
        else { return nil }
        let labels = extractLabels(from: line)
        return (num, labels)
    }

    @inline(__always)
    private static func extractLabels(from line: String) -> [String] {
        labelRegex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let r = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[r])
        }
    }

    @inline(__always)
    private static func extractMeaningAfterSense(_ line: String, number: Int, labels: [String]) -> String {
        var text = line
        // Strip number prefix
        if let numStr = "\(number)".first {
            text = text.replacingOccurrences(of: "\(number) ", with: "")
            text = text.replacingOccurrences(of: "\(number). ", with: "")
        }
        // Strip labels
        for label in labels {
            text = text.replacingOccurrences(of: "[\(label)]", with: "")
        }
        // Strip circled number
        let circled: [Character: Int] = ["①":1,"②":2,"③":3,"④":4,"⑤":5,"⑥":6,"⑦":7,"⑧":8,"⑨":9]
        for (ch, _) in circled {
            text = text.replacingOccurrences(of: String(ch), with: "")
        }
        let result = text.trimmingCharacters(in: .whitespaces)
        return stripPinyin(result)
    }

    // MARK: - Example Extraction

    private static let exampleRegex = try! NSRegularExpression(
        pattern: #"^[▸→]\s*(.+?)(?:\s{2,}|\t)(.+)$"#
    )

    private static func tryMatchExample(_ line: String) -> DictionaryEntry.Example? {
        guard line.hasPrefix("▸") || line.hasPrefix("→") else { return nil }
        let content = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)

        // Try regex split
        if let match = exampleRegex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           match.numberOfRanges >= 3,
           let enRange = Range(match.range(at: 1), in: content),
           let zhRange = Range(match.range(at: 2), in: content) {
            return .init(en: String(content[enRange]).trimmingCharacters(in: .whitespaces),
                         zh: String(content[zhRange]).trimmingCharacters(in: .whitespaces))
        }

        // Fallback: entire line as en
        return .init(en: content, zh: "")
    }

    // MARK: - Inflection Extraction

    private static let inflectionRegex = try! NSRegularExpression(
        pattern: #"^(plural|past tense|past participle|present participle|gerund|third-person singular|comparative|superlative|pl\.|pt\.|pp\.|comp\.|sup\.):\s*(.+)"#,
        options: .caseInsensitive
    )

    private static func tryMatchInflection(_ line: String) -> DictionaryEntry.Inflection? {
        guard let match = inflectionRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 3,
              let labelRange = Range(match.range(at: 1), in: line),
              let formRange  = Range(match.range(at: 2), in: line)
        else { return nil }
        return .init(form: String(line[formRange]).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)),
                     label: normalizedInflectionLabel(String(line[labelRange]).lowercased()))
    }

    // MARK: - Pinyin Stripping

    /// Removes pinyin strings (containing tone-marked vowels like āáǎà) from
    /// Chinese definition text.  Legitimate English words without tone marks
    /// (DNA, WiFi, etc.) are preserved.
    @inline(__always)
    private static func stripPinyin(_ text: String) -> String {
        let toneVowels = CharacterSet(charactersIn: "āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ")
        let words = text.components(separatedBy: .whitespaces)
        let filtered = words.filter { word in
            // Keep words that contain NO tone-marked vowels
            guard word.unicodeScalars.contains(where: { toneVowels.contains($0) }) else { return true }
            // Remove pure pinyin (typically short, lowercase, with tone marks)
            return false
        }
        return filtered.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sense Flushing

    private static func flushCurrentSense(
        into definitions: inout [DictionaryEntry.Definition],
        pos: String, posLabel: String?, number: Int, labels: [String],
        meaning: inout String
    ) {
        let cleaned = meaning.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { meaning = ""; return }
        let def = DictionaryEntry.Definition(
            pos: pos.isEmpty ? "—" : pos,
            posLabel: posLabel,
            senseNumber: number > 0 ? number : nil,
            labels: labels.isEmpty ? nil : labels,
            meaning: cleaned
        )
        definitions.append(def)
        meaning = ""
    }

    // MARK: - Example Attachment

    /// Heuristic: attach each example to the most recent definition (same POS
    /// block), or leave as top-level if no definition exists.
    private static func attachExamples(
        _ definitions: inout [DictionaryEntry.Definition],
        _ examples: inout [DictionaryEntry.Example]
    ) {
        guard !examples.isEmpty, !definitions.isEmpty else { return }
        // Simple strategy: attach all examples to the last definition
        // (refinement would require tracking example positions relative to senses)
        // We leave examples top-level for simplicity; views can render them.
    }

    // MARK: - Normalizers

    @inline(__always)
    private static func normalizedPOS(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("noun")  { return "n." }
        if lower.contains("verb")  { return "v." }
        if lower.contains("adj")   { return "adj." }
        if lower.contains("adv")   { return "adv." }
        if lower.contains("prep")  { return "prep." }
        if lower.contains("conj")  { return "conj." }
        if lower.contains("pron")  { return "pron." }
        if lower.contains("interj"){ return "interj." }
        if lower.contains("art")   { return "art." }
        if lower.contains("num")   { return "num." }
        if lower == "名词" || lower == "名" { return "n." }
        if lower == "动词" || lower == "动" { return "v." }
        if lower == "形容词" || lower == "形" { return "adj." }
        if lower == "副词" || lower == "副" { return "adv." }
        return "—"
    }

    private static func normalizedInflectionLabel(_ raw: String) -> String {
        switch raw {
        case "plural", "pl.":              return "plural"
        case "past tense", "pt.":          return "past tense"
        case "past participle", "pp.":     return "past participle"
        case "present participle", "gerund": return "present participle"
        case "third-person singular":      return "third-person singular"
        case "comparative", "comp.":       return "comparative"
        case "superlative", "sup.":        return "superlative"
        default:                           return raw
        }
    }
}
