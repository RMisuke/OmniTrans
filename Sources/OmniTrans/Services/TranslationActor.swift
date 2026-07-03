import Foundation

/// Isolated actor for all network I/O, SSE parsing, and JSON decoding.
/// Guarantees thread safety without locks; cooperatively cancels stale tasks.
actor TranslationActor {

    /// Active translation task — cancelled on new request.
    private var activeStreamTask: Task<Void, Never>?

    /// Per-request URLSession — invalidated after each stream to break C-level retain cycles.
    private var currentSession: URLSession?

    /// Create a disposable URLSession with zero caching.
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: config)
        currentSession = s
        return s
    }

    /// Destroy the current session to release all internal buffers.
    private func tearDownSession() {
        currentSession?.invalidateAndCancel()
        currentSession = nil
    }

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

    
    // MARK: - Dictionary lookup (JSON Mode)

    func translateDictionary(
        text: String,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage,
        provider: APIProvider
    ) -> AsyncThrowingStream<String, Error> {
        activeStreamTask?.cancel()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        text: text, sourceLang: sourceLang,
                        targetLang: targetLang, provider: provider,
                        continuation: continuation, isDictionaryMode: true
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

    // MARK: - Traditional MT (single-shot, used by TranslationService fallback)

    func mtTranslate(
        text: String,
        tgt: TranslationLanguage,
        provider: APIProvider
    ) async throws -> String {
        switch provider.kind {
        case .googleMT:
            return try await requestGoogleMT(text: text, tgt: tgt, provider: provider)
        case .bingMT:
            return try await requestBingMT(text: text, tgt: tgt, provider: provider)
        case .alibabaMT:
            return try await requestAlibabaMT(text: text, tgt: tgt, provider: provider)
        case .volcengineMT:
            return try await requestVolcengineMT(text: text, tgt: tgt, provider: provider)
        default:
            throw TranslationService.TranslationError.apiError("mtTranslate called for non-MT provider")
        }
    }

    // MARK: - Local Ollama fallback

    /// Delegates fallback resolution to FallbackRouter.
    func resolveWithFallback(_ provider: APIProvider) async -> (APIProvider, Bool) {
        await FallbackRouter.resolveWithFallback(provider)
    }

    // MARK: - Private: stream dispatch

    private func performStream(
        text: String, sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage, provider: APIProvider,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        isDictionaryMode: Bool = false
    ) async throws {
        switch provider.kind {
        case .openAI, .openAICompat:
            try await openAIStream(text, sourceLang, targetLang, provider, continuation, isDictionaryMode: isDictionaryMode)
        case .anthropic:
            try await anthropicStream(text, sourceLang, targetLang, provider, continuation, isDictionaryMode: isDictionaryMode)
        case .gemini:
            try await geminiStream(text, sourceLang, targetLang, provider, continuation, isDictionaryMode: isDictionaryMode)
        case .macOSNative:
            throw TranslationService.TranslationError.apiError("macOS Native handled outside actor")
        case .googleMT:
            try await performMockStream(continuation) {
                try await self.requestGoogleMT(text: text, tgt: targetLang, provider: provider)
            }
        case .bingMT:
            try await performMockStream(continuation) {
                try await self.requestBingMT(text: text, tgt: targetLang, provider: provider)
            }
        case .alibabaMT:
            try await performMockStream(continuation) {
                try await self.requestAlibabaMT(text: text, tgt: targetLang, provider: provider)
            }
        case .volcengineMT:
            try await performMockStream(continuation) {
                try await self.requestVolcengineMT(text: text, tgt: targetLang, provider: provider)
            }
        }
    }

    // ── OpenAI SSE ──

    private func openAIStream(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, _ c: AsyncThrowingStream<String, Error>.Continuation,
        isDictionaryMode: Bool = false
    ) async throws {
        let hint = isDictionaryMode ? buildDictionaryHint(tgt: tgt) : buildHint(src: src, tgt: tgt)
        guard let url = URL(string: "\(p.baseURL)/chat/completions") else {
            throw TranslationService.TranslationError.malformedURL("\(p.baseURL)/chat/completions")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        var body: [String: Any] = [
            "model": p.modelName, "temperature": 0.1,
            "max_tokens": p.maxTokens, "stream": true,
            "messages": [["role": "system", "content": hint], ["role": "user", "content": text]]
        ]
        if isDictionaryMode && (p.kind == .openAICompat) {
            body["response_format"] = ["type": "json_object"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = makeSession()
        let (bytes, resp) = try await session.bytes(for: req)
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
        let t = ThrottledStream(c)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let jsonData = Data(line.utf8.dropFirst(6))
            if line.contains("[DONE]") { continue }
            guard let chunk = try? decoder.decode(OAIStreamChunk.self, from: jsonData),
                  let content = chunk.choices?.first?.delta?.content,
                  !content.isEmpty
            else { continue }
            t.yield(content)
        }
        t.flush()
        tearDownSession()
    }

    // ── Anthropic SSE ──

    private func anthropicStream(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, _ c: AsyncThrowingStream<String, Error>.Continuation,
        isDictionaryMode: Bool = false
    ) async throws {
        let hint = isDictionaryMode ? buildDictionaryHint(tgt: tgt) : buildHint(src: src, tgt: tgt)
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

        let session = makeSession()
        let (bytes, resp) = try await session.bytes(for: req)
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

        let t = ThrottledStream(c)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let jsonData = Data(line.utf8.dropFirst(6))
            guard let event = try? JSONDecoder().decode(AnthStreamEvent.self, from: jsonData),
                  event.type == "content_block_delta",
                  let text = event.delta?.text, !text.isEmpty
            else { continue }
            t.yield(text)
        }
        t.flush()
        tearDownSession()
    }

    // ── Gemini SSE ──

    private func geminiStream(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, _ c: AsyncThrowingStream<String, Error>.Continuation,
        isDictionaryMode: Bool = false
    ) async throws {
        let hint = isDictionaryMode ? buildDictionaryHint(tgt: tgt) : buildHint(src: src, tgt: tgt)
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

        let session = makeSession()
        let (bytes, resp) = try await session.bytes(for: req)
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
        let t = ThrottledStream(c)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let jsonData = Data(line.utf8.dropFirst(6))
            guard let chunk = try? decoder.decode(GemStreamChunk.self, from: jsonData),
                  let text = chunk.candidates?.first?.content?.parts?.first?.text,
                  !text.isEmpty
            else { continue }
            t.yield(text)
        }
        t.flush()
    }

    // MARK: - Mock Stream (Traditional MT → single-token stream)

    /// Wraps a single-shot MT result as a one‑token AsyncThrowingStream,
    /// keeping the upper‑layer UI pipeline unchanged.
    private func performMockStream(
        _ continuation: AsyncThrowingStream<String, Error>.Continuation,
        block: () async throws -> String
    ) async throws {
        try Task.checkCancellation()
        let result = try await block()
        continuation.yield(result)
    }

    // ── Google Cloud Translation v2 ──

    private func requestGoogleMT(
        text: String, tgt: TranslationLanguage, provider: APIProvider
    ) async throws -> String {
        var components = URLComponents(string: provider.baseURL)!
        components.queryItems = [URLQueryItem(name: "key", value: provider.apiKey)]
        guard let url = components.url else {
            throw TranslationService.TranslationError.malformedURL(provider.baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        let body: [String: Any] = [
            "q": text,
            "target": tgt.languageCode.isEmpty ? "zh" : tgt.languageCode,
            "format": "text"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try Task.checkCancellation()
        let (data, resp) = try await makeSession().data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranslationService.TranslationError.apiError("Google MT HTTP error")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let translations = dataDict["translations"] as? [[String: Any]],
              let first = translations.first?["translatedText"] as? String
        else {
            throw TranslationService.TranslationError.invalidResponse
        }
        return first.htmlEntityDecoded()
    }

    // ── Microsoft Bing Translator v3 ──

    private func requestBingMT(
        text: String, tgt: TranslationLanguage, provider: APIProvider
    ) async throws -> String {
        let region = provider.customRegion.isEmpty ? "global" : provider.customRegion
        let targetLang = tgt.languageCode.isEmpty ? "zh-Hans" : tgt.languageCode
        guard let url = URL(string: "\(provider.baseURL)/translate?api-version=3.0&to=\(targetLang)") else {
            throw TranslationService.TranslationError.malformedURL(provider.baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(provider.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        req.timeoutInterval = 20

        let body: [[String: String]] = [["Text": text]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try Task.checkCancellation()
        let (data, resp) = try await makeSession().data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranslationService.TranslationError.apiError("Bing MT HTTP error")
        }
        struct BingNode: Codable { let text: String }
        struct BingResponse: Codable { let translations: [BingNode] }
        let result = try JSONDecoder().decode([BingResponse].self, from: data)
        return result.first?.translations.first?.text ?? ""
    }

    // ── Alibaba Cloud Machine Translation ──

    private func requestAlibabaMT(
        text: String, tgt: TranslationLanguage, provider: APIProvider
    ) async throws -> String {
        let targetLang = tgt.languageCode.isEmpty ? "zh" : tgt.languageCode
        let signedQuery = AlibabaCloudSigner.signedQuery(
            accessKeyId: provider.apiKey,
            accessKeySecret: provider.apiSecret,
            sourceText: text,
            targetLanguage: targetLang
        )
        // Alibaba MT uses HTTPS with signed query string
        let urlString = "https://mt.cn-hangzhou.aliyuncs.com/?\(signedQuery)"
        print("[AlibabaMT] URL: \(urlString.prefix(200))...")
        guard let url = URL(string: urlString) else {
            throw TranslationService.TranslationError.malformedURL(provider.baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20

        try Task.checkCancellation()
        let (data, resp) = try await makeSession().data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[AlibabaMT] no HTTP response, body: \(body.prefix(300))")
            throw TranslationService.TranslationError.networkError("无效响应")
        }
        print("[AlibabaMT] HTTP \(http.statusCode)")
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[AlibabaMT] error body: \(body.prefix(500))")
            // Parse XML error from Alibaba Cloud
            if body.contains("<Code>"), body.contains("<Message>") {
                let code = body.extractXMLTag("Code") ?? "Unknown"
                let msg = body.extractXMLTag("Message") ?? body
                throw TranslationService.TranslationError.apiError("阿里云: [\(code)] \(msg)")
            }
            throw TranslationService.TranslationError.apiError("阿里云返回 HTTP \(http.statusCode)")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        print("[AlibabaMT] body: \(body.prefix(300))")

        // Alibaba MT returns XML, not JSON
        if let translated = body.extractXMLTag("Translated") {
            return translated
        }
        // Check for error
        if let code = body.extractXMLTag("Code"), let msg = body.extractXMLTag("Message") {
            throw TranslationService.TranslationError.apiError("阿里云 [\(code)] \(msg)")
        }
        throw TranslationService.TranslationError.invalidResponse
    }


    // MARK: - Volcengine MT (火山翻译)

    private func requestVolcengineMT(
        text: String,
        tgt: TranslationLanguage,
        provider: APIProvider
    ) async throws -> String {
        let key = provider.apiKey
        let secret = provider.apiSecret
        guard !key.isEmpty, !secret.isEmpty else {
            throw TranslationService.TranslationError.apiError("火山翻译需要 Access Key 和 Secret Key")
        }

        let tgtCode = tgt == .auto ? "zh" : tgt.languageCode
        let query = VolcengineSigner.signedQuery(
            accessKey: key,
            secretKey: secret,
            sourceText: text,
            sourceLanguage: "auto",
            targetLanguage: tgtCode
        )

        guard let url = URL(string: "https://translate.volcengineapi.com/?\(query)") else {
            throw TranslationService.TranslationError.malformedURL("https://translate.volcengineapi.com")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15

        try Task.checkCancellation()
        let (data, resp) = try await makeSession().data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("no response")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        print("[VolcengineMT] body: \(body.prefix(300))")

        guard http.statusCode == 200 else {
            throw TranslationService.TranslationError.apiError("火山翻译 HTTP \(http.statusCode): \(body.prefix(200))")
        }

        // Volcengine returns JSON: {"TranslationList":[{"Translation":"..."}], ...}
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["TranslationList"] as? [[String: Any]],
           let first = list.first,
           let translated = first["Translation"] as? String {
            return translated.htmlEntityDecoded()
        }

        // Check for error
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["ResponseMetadata"] as? [String: Any],
           let errCode = err["Error"] as? [String: Any] {
            let code = errCode["Code"] as? String ?? "Unknown"
            let msg = errCode["Message"] as? String ?? "Unknown"
            throw TranslationService.TranslationError.apiError("火山翻译 [\(code)] \(msg)")
        }

        throw TranslationService.TranslationError.invalidResponse
    }

    // MARK: - Helpers

    /// Dedicated dictionary profile — XML-tag structured for JSON Mode reliability.
    /// Not user-configurable: dictionary output requires strict schema adherence.
    private func buildDictionaryHint(tgt: TranslationLanguage) -> String {
        let langName = tgt.rawValue
        return """
You are an expert lexicographer and dictionary assistant.
Analyze the following __SOURCE_LANG__ word and provide a detailed dictionary entry in __TARGET_LANG__.

Expected JSON schema (fill precisely):
{
  "is_word": true,
  "phonetic": "/IPA notation/",
  "definitions": [
    {"pos": "n.", "meaning": "definition in \(langName)"}
  ],
  "examples": [
    {"en": "example sentence in source language", "zh": "translation in \(langName)"}
  ]
}

<Rules>
- ALL "meaning" values MUST be written in \(langName).
- ALL "zh" example translations MUST be in \(langName).
- "pos" values: use standard English abbreviations (n., v., adj., adv., prep., conj., pron.).
- "phonetic": use IPA notation or empty string if not applicable.
- List ALL common definitions. Provide at least 2 examples.
- Use the query word in each example sentence.
</Rules>


[CRITICAL FORMAT CONSTRAINT]
You must respond ONLY with a valid JSON object. Do NOT wrap in Markdown code blocks (no ```json).
No explanations, no intro, no outro — pure JSON only.
"""
    }

    private func buildHint(src: TranslationLanguage, tgt: TranslationLanguage) -> String {
        let sourceName = src == .auto ? "Auto-Detected" : src.rawValue
        let targetName = tgt.rawValue

        // Read custom prompt from UserDefaults (avoids MainActor isolation)
        if let data = UserDefaults.standard.data(forKey: "custom_prompt"),
           let cp = try? JSONDecoder().decode(CustomPrompt.self, from: data) {
            let base = cp.enabled ? cp.text : CustomPrompt.defaultPrompt
            var prompt = base
                .replacingOccurrences(of: "__SOURCE_LANG__", with: sourceName)
                .replacingOccurrences(of: "__TARGET_LANG__", with: targetName)
            prompt += """


[CRITICAL FORMAT CONSTRAINT]
Translate directly. No introduction, no meta-commentary.
Preserve original formatting and Markdown tags if present.
"""
            return prompt
        }

        // Fallback to built-in default
        var prompt = CustomPrompt.defaultPrompt
            .replacingOccurrences(of: "__SOURCE_LANG__", with: sourceName)
            .replacingOccurrences(of: "__TARGET_LANG__", with: targetName)
        prompt += """


[CRITICAL FORMAT CONSTRAINT]
Translate directly. No introduction, no meta-commentary.
Preserve original formatting and Markdown tags if present.
"""
        return prompt
    }
}


// MARK: - SSE Throttle (80ms buffer)

/// Accumulates SSE tokens and flushes them to the continuation every ~80ms,
/// preventing SwiftUI from re-rendering on every single token.
private final class ThrottledStream {
    private var buffer = ""
    private var flushTask: Task<Void, Never>?
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let intervalNs: UInt64 = 80_000_000

    init(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ chunk: String) {
        buffer += chunk
        scheduleFlush()
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        if !buffer.isEmpty {
            continuation.yield(buffer)
            buffer = ""
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.intervalNs ?? 80_000_000)
            guard let self, !Task.isCancelled, !self.buffer.isEmpty else { return }
            let text = self.buffer
            self.buffer = ""
            self.flushTask = nil
            self.continuation.yield(text)
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

// MARK: - TranslationEngineProtocol conformance

extension TranslationActor: TranslationEngineProtocol {
    /// Unified entry point called by the factory.
    /// Routes to the correct internal pipeline based on mode.
    nonisolated func execute(
        text: String,
        provider: APIProvider,
        isDictionaryMode: Bool,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage
    ) -> AsyncThrowingStream<String, Error> {
        // Capture shared as a local constant so the nonisolated context can reference it.
        let actor = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                let stream: AsyncThrowingStream<String, Error>
                if isDictionaryMode && !provider.kind.isTraditionalMT && provider.kind != .macOSNative {
                    stream = await actor.translateDictionary(
                        text: text, sourceLang: sourceLang,
                        targetLang: targetLang, provider: provider
                    )
                } else {
                    stream = await actor.translateStream(
                        text: text, sourceLang: sourceLang,
                        targetLang: targetLang, provider: provider
                    )
                }
                do {
                    for try await chunk in stream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
