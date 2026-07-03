import Foundation

/// Adapter that wraps macOS native dictionary + Translation framework
/// into a unified `TranslationEngineProtocol` stream.
///
/// - Dictionary mode: sync lookup via `MacOSNativeProvider.lookupWord` (all macOS versions)
/// - Translation mode: single-shot via `SystemTranslationEngine` (macOS 26+)
///   with language-availability pre-check and Chinese-language guidance.
struct MacOSNativeEngineAdapter: TranslationEngineProtocol {

    func execute(
        text: String,
        provider: APIProvider,
        isDictionaryMode: Bool,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if isDictionaryMode {
                    // ── Dictionary mode: local CoreServices lookup ──
                    let entry = await MacOSNativeProvider.lookupWord(text)
                    if entry.isWord {
                        let summary = buildDictionarySummary(from: entry)
                        continuation.yield(summary)
                        continuation.finish()
                    } else {
                        continuation.finish(
                            throwing: TranslationService.TranslationError.apiError("系统词典未收录该词")
                        )
                    }
                } else if #available(macOS 26.0, *) {
                    // ── Translation mode: macOS 26+ ANE engine ──
                    let engine = SystemTranslationEngine()
                    do {
                        let result = try await engine.translate(
                            text: text,
                            sourceLang: sourceLang,
                            targetLang: targetLang
                        )
                        continuation.yield(result)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } else {
                    // ── macOS 25 or earlier ──
                    continuation.finish(
                        throwing: TranslationService.TranslationError.apiError(
                            "原生离线翻译需要 macOS 26 或更高版本。请升级系统或切换至云端 API。"
                        )
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Dictionary summary formatting

    private func buildDictionarySummary(from entry: DictionaryEntry) -> String {
        guard entry.isWord else { return "未收录" }
        var lines: [String] = [entry.word]
        if !entry.phonetic.isEmpty { lines.append(entry.phonetic) }
        for def in entry.definitions {
            let pos = def.pos == "—" ? "" : "[\(def.pos)] "
            lines.append("\(pos)\(def.meaning)")
        }
        return lines.joined(separator: "\n")
    }
}
