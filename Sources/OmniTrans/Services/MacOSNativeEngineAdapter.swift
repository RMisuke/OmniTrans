import Foundation

/// Adapter that wraps macOS native dictionary + Translation framework
/// into a unified `TranslationEngineProtocol` stream.
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
                    // System dictionary lookup (all macOS versions)
                    let entry = MacOSNativeProvider.lookupWord(text)
                    if entry.isWord {
                        // Yield a simple readable summary (NativeDictionaryView will render the structured entry)
                        let summary = buildDictionarySummary(from: entry)
                        continuation.yield(summary)
                    } else {
                        continuation.finish(
                            throwing: TranslationService.TranslationError.apiError("系统词典未收录该词")
                        )
                        return
                    }
                } else {
                    // Paragraph translation via macOS 15+ Translation framework
                    guard #available(macOS 15.0, *) else {
                        continuation.finish(
                            throwing: TranslationService.TranslationError.apiError(
                                "原生离线翻译需要 macOS 15 (Sequoia) 或更高版本。"
                            )
                        )
                        return
                    }
                    do {
                        let stream = MacOSNativeProvider.translateStream(
                            text, sourceLang: sourceLang, targetLang: targetLang
                        )
                        for try await chunk in stream {
                            continuation.yield(chunk)
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Build a plain-text summary from a DictionaryEntry (for streaming compatibility).
    private func buildDictionarySummary(from entry: DictionaryEntry) -> String {
        var lines: [String] = [entry.word]
        if !entry.phonetic.isEmpty { lines.append(entry.phonetic) }
        for def in entry.definitions {
            let pos = def.pos == "—" ? "" : "[\(def.pos)] "
            lines.append("\(pos)\(def.meaning)")
        }
        return lines.joined(separator: "\n")
    }
}
