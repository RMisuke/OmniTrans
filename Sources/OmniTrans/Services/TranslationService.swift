import Foundation

// MARK: - Unified Error Types

/// All translation errors share this type — used by both streaming and
/// non-streaming paths.
enum TranslationService {
    struct TranslationResult: Sendable {
        let text: String
        let providerName: String
        let model: String
        let tokensUsed: Int
    }

    enum TranslationError: LocalizedError, Sendable {
        case noProvider, apiError(String), invalidResponse, networkError(String), malformedURL(String)
        var errorDescription: String? {
            switch self {
            case .noProvider:        return "没有可用的 API 配置"
            case .apiError(let msg):  return "API 错误: \(msg)"
            case .invalidResponse:    return "无法解析返回结果"
            case .networkError(let e): return "网络错误: \(e)"
            case .malformedURL(let u): return "无效的 API 地址: \(u)"
            }
        }
    }

    // MARK: - Non-streaming (fallback) — delegates to TranslationActor

    /// Single-shot (non‑streaming) translation for all provider kinds.
    /// AI providers (OpenAI, Anthropic, Gemini) use REST single-shot.
    /// Traditional MT providers (Google, Bing, Alibaba, Volcengine) use
    /// their native single-shot APIs.
    /// macOS Native is handled locally outside this path.
    static func translate(
        text: String, sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage, using provider: APIProvider
    ) async throws -> TranslationResult {
        guard provider.kind != .macOSNative else {
            throw TranslationError.apiError("macOS Native should be handled locally")
        }
        return try await TranslationActor().nonStreamingTranslate(
            text: text, sourceLang: sourceLang,
            targetLang: targetLang, provider: provider
        )
    }
}

// ── Non-streaming response types (shared by TranslationActor) ──
struct OAIResp: Codable, Sendable {
    struct Choice: Codable, Sendable { struct Message: Codable, Sendable { let content: String }; let message: Message }
    struct Usage: Codable, Sendable { let totalTokens: Int; enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens" } }
    let choices: [Choice]; let usage: Usage?
}
struct AnthResp: Codable, Sendable {
    struct Content: Codable, Sendable { let type: String; let text: String }
    struct Usage: Codable, Sendable { let inputTokens: Int; let outputTokens: Int; enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens"; case outputTokens = "output_tokens" } }
    let content: [Content]; let usage: Usage?
}
struct GemResp: Codable, Sendable {
    struct Cand: Codable, Sendable { struct Cont: Codable, Sendable { struct Part: Codable, Sendable { let text: String }; let parts: [Part]? }; let content: Cont? }
    struct Usage: Codable, Sendable { let totalTokenCount: Int }
    let candidates: [Cand]?; let usageMetadata: Usage?
}

