import Foundation

/// Isolated actor for all network I/O, SSE parsing, and JSON decoding.
/// Guarantees thread safety without locks; cooperatively cancels stale tasks.
actor TranslationActor {
    static let shared = TranslationActor()

    /// Active translation task — cancelled on new request.
    private var activeStreamTask: Task<Void, Never>?

    // MARK: - Streaming (primary path)

    func translateStream(
        text: String,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage,
        provider: APIProvider
    ) -> AsyncThrowingStream<String, Error> {
        // Cancel previous task — cooperative cancellation via URLSession.bytes
        activeStreamTask?.cancel()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        text: text, sourceLang: sourceLang,
                        targetLang: targetLang, provider: provider,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            activeStreamTask = task
        }
    }

    // MARK: - Non-streaming (fallback)

    func translate(
        text: String,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage,
        provider: APIProvider
    ) async throws -> TranslationService.TranslationResult {
        try await TranslationService.translate(
            text: text, sourceLang: sourceLang,
            targetLang: targetLang, using: provider
        )
    }

    // MARK: - Local Ollama fallback

    /// Probes local Ollama; if alive, remaps provider to local.
    func resolveWithFallback(_ provider: APIProvider) async -> (APIProvider, Bool) {
        do {
            // Quick connectivity test to original provider
            _ = try await TranslationService.translate(
                text: "test", sourceLang: .auto,
                targetLang: .english, using: provider
            )
            return (provider, false) // online — no fallback needed
        } catch {
            // Probe local Ollama
            guard await probeLocalOllama() else {
                return (provider, false) // offline, no local either
            }
            // Remap to local
            var local = provider
            local.baseURL = "http://127.0.0.1:11434/v1"
            local.modelName = "qwen2.5:1.5b"
            local.kind = .openAICompat
            return (local, true) // fallback active
        }
    }

    private func probeLocalOllama() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/v1/models") else {
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

    // MARK: - Private: stream dispatch

    private func performStream(
        text: String, sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage, provider: APIProvider,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        switch provider.kind {
        case .openAI, .openAICompat:
            try await openAIStream(text, sourceLang, targetLang, provider, continuation)
        case .anthropic:
            try await anthropicStream(text, sourceLang, targetLang, provider, continuation)
        case .gemini:
            try await geminiStream(text, sourceLang, targetLang, provider, continuation)
        }
    }

    // ── OpenAI SSE ──

    private func openAIStream(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, _ c: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let hint = buildHint(src: src, tgt: tgt)
        guard let url = URL(string: "\(p.baseURL)/chat/completions") else {
            throw TranslationService.TranslationError.malformedURL("\(p.baseURL)/chat/completions")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "model": p.modelName, "temperature": p.temperature,
            "max_tokens": p.maxTokens, "stream": true,
            "messages": [["role": "system", "content": hint], ["role": "user", "content": text]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("invalid")
        }
        guard http.statusCode == 200 else {
            var errBody = Data()
            for try await b in bytes { errBody.append(b); if errBody.count > 1024 { break } }
            let msg = (try? JSONDecoder().decode(OAIErr.self, from: errBody))?.error.message
                ?? "HTTP \(http.statusCode)"
            throw TranslationService.TranslationError.apiError(msg)
        }

        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }
            guard line.hasPrefix("data: ") else { continue }
            let jsonData = Data(line.utf8.dropFirst(6))
            if line.contains("[DONE]") { continue }
            guard let chunk = try? decoder.decode(OAIStreamChunk.self, from: jsonData),
                  let content = chunk.choices?.first?.delta?.content,
                  !content.isEmpty
            else { continue }
            c.yield(content)
        }
    }

    // ── Anthropic SSE ──

    private func anthropicStream(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, _ c: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let hint = buildHint(src: src, tgt: tgt)
        guard let url = URL(string: "\(p.baseURL)/v1/messages") else {
            throw TranslationService.TranslationError.malformedURL("\(p.baseURL)/v1/messages")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(p.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "model": p.modelName, "max_tokens": p.maxTokens,
            "stream": true,
            "messages": [["role": "user", "content": "\(hint)\n\n\(text)"]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("invalid")
        }
        guard http.statusCode == 200 else {
            var errBody = Data()
            for try await b in bytes { errBody.append(b); if errBody.count > 1024 { break } }
            let msg = (try? JSONDecoder().decode(AnthErr.self, from: errBody))?.error.message
                ?? "HTTP \(http.statusCode)"
            throw TranslationService.TranslationError.apiError(msg)
        }

        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }
            guard line.hasPrefix("data: ") else { continue }
            let jsonData = Data(line.utf8.dropFirst(6))
            guard let event = try? JSONDecoder().decode(AnthStreamEvent.self, from: jsonData),
                  event.type == "content_block_delta",
                  let text = event.delta?.text, !text.isEmpty
            else { continue }
            c.yield(text)
        }
    }

    // ── Gemini SSE ──

    private func geminiStream(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, _ c: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let hint = buildHint(src: src, tgt: tgt)
        guard let url = URL(string: "\(p.baseURL)/models/\(p.modelName):streamGenerateContent?alt=sse") else {
            throw TranslationService.TranslationError.malformedURL("\(p.baseURL)/models/\(p.modelName):streamGenerateContent?alt=sse")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(p.apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "contents": [["parts": [["text": "\(hint)\n\n\(text)"]]]],
            "generationConfig": ["temperature": p.temperature, "maxOutputTokens": p.maxTokens]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("invalid")
        }
        guard http.statusCode == 200 else {
            var errBody = Data()
            for try await b in bytes { errBody.append(b); if errBody.count > 1024 { break } }
            let msg = (try? JSONDecoder().decode(GemErr.self, from: errBody))?.error.message
                ?? "HTTP \(http.statusCode)"
            throw TranslationService.TranslationError.apiError(msg)
        }

        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }
            guard line.hasPrefix("data: ") else { continue }
            let jsonData = Data(line.utf8.dropFirst(6))
            guard let chunk = try? decoder.decode(GemStreamChunk.self, from: jsonData),
                  let text = chunk.candidates?.first?.content?.parts?.first?.text,
                  !text.isEmpty
            else { continue }
            c.yield(text)
        }
    }

    // MARK: - Helpers

    private func buildHint(src: TranslationLanguage, tgt: TranslationLanguage) -> String {
        if src == .auto {
            return "Translate to \(tgt.languageCode). Output translation only."
        } else {
            return "Translate \(src.languageCode) to \(tgt.languageCode). Output translation only."
        }
    }
}

// ── Inline response types (same as TranslationService) ──

private struct OAIErr: Codable {
    struct Detail: Codable { let message: String }
    let error: Detail
}
private struct OAIStreamChunk: Codable {
    struct Choice: Codable { struct Delta: Codable { let content: String? }; let delta: Delta? }
    let choices: [Choice]?
}
private struct AnthErr: Codable {
    struct Detail: Codable { let message: String }
    let error: Detail
}
private struct AnthStreamEvent: Codable {
    struct Delta: Codable { let text: String?; let type: String? }
    let type: String?; let delta: Delta?
}
private struct GemErr: Codable {
    struct Detail: Codable { let message: String }
    let error: Detail
}
private struct GemStreamChunk: Codable {
    struct Cand: Codable { struct Cont: Codable { struct Part: Codable { let text: String? }; let parts: [Part]? }; let content: Cont? }
    let candidates: [Cand]?
}
