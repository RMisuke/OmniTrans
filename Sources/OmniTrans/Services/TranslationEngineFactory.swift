import Foundation

// MARK: - Engine Factory

/// Stateless factory that maps a routing context to the correct engine implementation.
/// Follows the Open-Closed Principle: adding a new provider kind only requires
/// registering it here — AppState stays untouched.
enum TranslationEngineFactory {

    /// Returns the best-fit engine for the given context.
    /// - Parameter context: Routing information (text, provider, word flag)
    /// - Returns: A concrete `TranslationEngineProtocol` implementation
    static func makeEngine(context: EngineRoutingContext) -> TranslationEngineProtocol {
        // Branch 1: macOS native (offline dictionary + ANE translation)
        if context.provider.kind == .macOSNative {
            return MacOSNativeEngineAdapter()
        }

        // Branch 2: AI / LLM (OpenAI, Claude, Gemini, Ollama, compat…)
        //           AND traditional MT (Google, Bing, Alibaba)
        // Both are handled by TranslationActor — its internal performStream
        // dispatches SSE for AI and performMockStream for MT.
        return TranslationActor.shared
    }
}
