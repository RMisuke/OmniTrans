import Foundation

enum TranslationService {
    struct TranslationResult {
        let text: String
        let providerName: String
        let model: String
        let tokensUsed: Int
    }

    enum TranslationError: LocalizedError {
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

    // MARK: - Non-streaming (fallback)

    static func translate(text: String, sourceLang: TranslationLanguage, targetLang: TranslationLanguage, using provider: APIProvider) async throws -> TranslationResult {
        switch provider.kind {
        case .openAI, .openAICompat: return try await openAI(text, sourceLang, targetLang, provider)
        case .anthropic:             return try await anthropic(text, sourceLang, targetLang, provider)
        case .gemini:                return try await gemini(text, sourceLang, targetLang, provider)
        case .macOSNative:         throw TranslationError.apiError("macOS Native should be handled locally")
        case .googleMT:             return try await mtFallback(text, sourceLang, targetLang, provider, kind: .googleMT)
        case .bingMT:               return try await mtFallback(text, sourceLang, targetLang, provider, kind: .bingMT)
        case .alibabaMT:            return try await mtFallback(text, sourceLang, targetLang, provider, kind: .alibabaMT)
        case .volcengineMT:         return try await mtFallback(text, sourceLang, targetLang, provider, kind: .volcengineMT)
        }
    }

    /// Non-streaming fallback for traditional MT providers.
    /// Delegates to TranslationActor for single-shot translation.
    private static func mtFallback(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, kind: ProviderKind
    ) async throws -> TranslationResult {
        let result = try await TranslationActor.shared.mtTranslate(
            text: text, tgt: tgt, provider: p
        )
        return TranslationResult(
            text: result, providerName: p.name, model: p.modelName, tokensUsed: 0
        )
    }


    // MARK: - OpenAI (non-streaming)

    private static func openAI(_ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage, _ p: APIProvider) async throws -> TranslationResult {
        guard let url = URL(string: "\(p.baseURL)/chat/completions") else { throw TranslationError.malformedURL("\(p.baseURL)/chat/completions") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let hint = buildHint(src: src, tgt: tgt)
        let body: [String: Any] = [
            "model": p.modelName, "temperature": p.temperature,
            "max_tokens": p.maxTokens,
            "messages": [["role": "system", "content": hint], ["role": "user", "content": text]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TranslationError.networkError("invalid") }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(OAIErr.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw TranslationError.apiError(msg)
        }
        let r = try JSONDecoder().decode(OAIResp.self, from: data)
        guard let c = r.choices.first?.message.content else { throw TranslationError.invalidResponse }
        return TranslationResult(text: c.trimmingCharacters(in: .whitespacesAndNewlines), providerName: p.name, model: p.modelName, tokensUsed: r.usage?.totalTokens ?? 0)
    }


    // MARK: - Anthropic (non-streaming)

    private static func anthropic(_ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage, _ p: APIProvider) async throws -> TranslationResult {
        guard let url = URL(string: "\(p.baseURL)/v1/messages") else { throw TranslationError.malformedURL("\(p.baseURL)/v1/messages") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(p.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20

        let hint = buildHint(src: src, tgt: tgt)
        let body: [String: Any] = [
            "model": p.modelName, "max_tokens": p.maxTokens, "temperature": p.temperature,
            "system": hint, "messages": [["role": "user", "content": text]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TranslationError.networkError("invalid") }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(AnthErr.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw TranslationError.apiError(msg)
        }
        let r = try JSONDecoder().decode(AnthResp.self, from: data)
        guard let c = r.content.first, c.type == "text" else { throw TranslationError.invalidResponse }
        return TranslationResult(text: c.text.trimmingCharacters(in: .whitespacesAndNewlines), providerName: p.name, model: p.modelName, tokensUsed: (r.usage?.inputTokens ?? 0) + (r.usage?.outputTokens ?? 0))
    }


    // MARK: - Gemini (non-streaming)

    private static func gemini(_ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage, _ p: APIProvider) async throws -> TranslationResult {
        guard let url = URL(string: "\(p.baseURL)/models/\(p.modelName):generateContent") else { throw TranslationError.malformedURL("\(p.baseURL)/models/\(p.modelName):generateContent") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(p.apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 20

        let hint = buildHint(src: src, tgt: tgt)
        let body: [String: Any] = [
            "contents": [["parts": [["text": "\(hint)\n\n\(text)"]]]],
            "generationConfig": ["temperature": p.temperature, "maxOutputTokens": p.maxTokens]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TranslationError.networkError("invalid") }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(GemErr.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw TranslationError.apiError(msg)
        }
        let r = try JSONDecoder().decode(GemResp.self, from: data)
        guard let t = r.candidates?.first?.content?.parts?.first?.text else { throw TranslationError.invalidResponse }
        return TranslationResult(text: t.trimmingCharacters(in: .whitespacesAndNewlines), providerName: p.name, model: p.modelName, tokensUsed: r.usageMetadata?.totalTokenCount ?? 0)
    }


    // MARK: - Helpers

    private static func buildHint(src: TranslationLanguage, tgt: TranslationLanguage) -> String {
        if src == .auto {
            return "Translate to \(tgt.languageCode). Output translation only."
        } else {
            return "Translate \(src.languageCode) to \(tgt.languageCode). Output translation only."
        }
    }
}

// ── Non-streaming response types ──
private struct OAIResp: Codable {
    struct Choice: Codable { struct Message: Codable { let content: String }; let message: Message }
    struct Usage: Codable { let totalTokens: Int; enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens" } }
    let choices: [Choice]; let usage: Usage?
}
private struct OAIErr: Codable { struct Detail: Codable { let message: String }; let error: Detail }
private struct AnthResp: Codable {
    struct Content: Codable { let type: String; let text: String }
    struct Usage: Codable { let inputTokens: Int; let outputTokens: Int; enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens"; case outputTokens = "output_tokens" } }
    let content: [Content]; let usage: Usage?
}
private struct AnthErr: Codable { struct Detail: Codable { let message: String }; let error: Detail }
private struct GemResp: Codable {
    struct Cand: Codable { struct Cont: Codable { struct Part: Codable { let text: String }; let parts: [Part]? }; let content: Cont? }
    struct Usage: Codable { let totalTokenCount: Int }
    let candidates: [Cand]?; let usageMetadata: Usage?
}
private struct GemErr: Codable { struct Detail: Codable { let message: String }; let error: Detail }

