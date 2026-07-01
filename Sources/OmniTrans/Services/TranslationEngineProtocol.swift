import Foundation

// MARK: - Unified Translation Engine Protocol

/// All translation engines (AI, MT, native) conform to this single protocol,
/// enabling the factory to swap implementations without touching AppState routing.
protocol TranslationEngineProtocol {
    /// Execute translation or dictionary lookup, returning a token stream.
    /// - Parameters:
    ///   - text: Source text (word or sentence)
    ///   - provider: The API provider configuration
    ///   - isDictionaryMode: If true, LLM engines use JSON Mode dictionary prompt
    ///   - sourceLang: Source language hint
    ///   - targetLang: Target language for output
    /// - Returns: AsyncThrowingStream yielding incremental text chunks
    func execute(
        text: String,
        provider: APIProvider,
        isDictionaryMode: Bool,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Routing Context

/// Captures everything the factory needs to pick the right engine.
struct EngineRoutingContext {
    let text: String
    let provider: APIProvider
    let isWord: Bool
}
