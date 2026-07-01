import Foundation

/// Isolated fallback routing: probes local Ollama health and remaps providers
/// when the primary API is unreachable. Extracted from TranslationActor for
/// independent evolution and testability.
enum FallbackRouter {
    private static let ollamaBaseURL = "http://127.0.0.1:11434/v1"
    private static let fallbackModel = "qwen2.5:1.5b"

    /// Heartbeat probe: returns true if local Ollama is alive and responding.
    static func probeLocalOllama() async -> Bool {
        guard let url = URL(string: "\(ollamaBaseURL)/models") else {
            return false
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Attempts a quick connectivity check against the primary provider.
    /// On failure, probes local Ollama and — if alive — remaps the provider
    /// to the local endpoint.
    /// - Returns: The resolved provider and a flag indicating whether fallback is active.
    static func resolveWithFallback(_ provider: APIProvider) async -> (APIProvider, Bool) {
        do {
            _ = try await TranslationService.translate(
                text: "test", sourceLang: .auto,
                targetLang: .english, using: provider
            )
            return (provider, false)
        } catch {
            guard await probeLocalOllama() else {
                return (provider, false)
            }
            var local = provider
            local.baseURL = ollamaBaseURL
            local.modelName = fallbackModel
            local.kind = .openAICompat
            return (local, true)
        }
    }
}
