import Foundation

// MARK: - Shared URLSession (HTTP/2 Pipelining + Connection Reuse)

/// Global singleton `URLSession` configured for HTTP/2 multiplexing and
/// connection reuse.  All translation engines (AI streaming, MT single-shot)
/// share this session to eliminate per-request TCP/TLS handshake overhead.
///
/// ## Configuration
/// - `httpShouldUsePipelining = true` — enables HTTP/2 multiplexing
/// - `httpMaximumConnectionsPerHost = 10` — allows concurrent streams
/// - No URL cache — SSE streaming is incompatible with caching
/// Module-internal shared `URLSession` singleton — used by `TranslationActor`
/// and `TranslationService` for all HTTP requests.  HTTP/2 multiplexing
/// eliminates per-request TCP/TLS handshake overhead.
let sharedURLSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpShouldUsePipelining = true
    config.httpMaximumConnectionsPerHost = 10
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    // Keep-Alive is enabled by default for HTTP/1.1+ with default config
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config)
}()

// MARK: - Translation Actor

/// Isolated actor for all network I/O, SSE parsing, and JSON decoding.
/// Guarantees thread safety without locks; cooperatively cancels stale tasks.
actor TranslationActor {

    /// Active translation task — cancelled on new request.
    private var activeStreamTask: Task<Void, Never>?

    /// Returns the shared `URLSession` with HTTP/2 pipelining enabled.
    /// No per-request session creation — all requests reuse the same
    /// connection pool for zero additional TCP/TLS handshake latency.
    private func makeSession() -> URLSession {
        sharedURLSession
    }

    // MARK: - Generic Network & SSE Helpers

    /// Executes an HTTP request, validates status 200, returns response data.
    /// Used by all traditional MT methods to eliminate boilerplate.
    private func executeMTRequest(_ req: URLRequest, label: String) async throws -> Data {
        try Task.checkCancellation()
        let (data, resp) = try await makeSession().data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("\(label): 无效响应")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationService.TranslationError.apiError("\(label) HTTP \(http.statusCode): \(body.prefix(200))")
        }
        return data
    }

    /// Generic SSE stream parser: reads lines from `bytes`, decodes each `data:` chunk
    /// as `T`, extracts text via `extractText`, and yields throttled tokens.
    private func parseSSEStream<T: Decodable>(
        bytes: URLSession.AsyncBytes,
        throttle: ThrottledStream,
        decoder: JSONDecoder = JSONDecoder(),
        extractText: @escaping (T) -> String?
    ) async throws {
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "), !line.contains("[DONE]") else { continue }
            let jsonData = Data(line.utf8.dropFirst(6))
            guard let chunk = try? decoder.decode(T.self, from: jsonData),
                  let text = extractText(chunk), !text.isEmpty
            else { continue }
            throttle.yield(text)
        }
    }

    /// Reads the error body from a failed SSE response (first 1024 bytes).
    private func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var errBody = Data()
        for try await b in bytes { errBody.append(b); if errBody.count > 1024 { break } }
        return errBody
    }

    /// Checks the HTTP response from an SSE stream; throws with the provider's error format.
    private func validateSSEResponse(
        http: HTTPURLResponse?, bytes: URLSession.AsyncBytes,
        errorDecoder: (Data) -> String
    ) async throws {
        guard let http, http.statusCode == 200 else {
            let body = try await readErrorBody(from: bytes)
            let msg = errorDecoder(body)
            throw TranslationService.TranslationError.apiError(msg)
        }
    }

    // MARK: - Streaming (primary path)

    func translateStream(
        text: String,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage,
        provider: APIProvider,
        context: CapturedContext? = nil
    ) -> AsyncThrowingStream<String, Error> {
        activeStreamTask?.cancel()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        text: text, sourceLang: sourceLang,
                        targetLang: targetLang, provider: provider,
                        continuation: continuation, context: context
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
        provider: APIProvider,
        context: CapturedContext? = nil
    ) -> AsyncThrowingStream<String, Error> {
        activeStreamTask?.cancel()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        text: text, sourceLang: sourceLang,
                        targetLang: targetLang, provider: provider,
                        continuation: continuation, isDictionaryMode: true, context: context
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
        case .googleMT:     return try await requestGoogleMT(text: text, tgt: tgt, provider: provider)
        case .bingMT:       return try await requestBingMT(text: text, tgt: tgt, provider: provider)
        case .alibabaMT:    return try await requestAlibabaMT(text: text, tgt: tgt, provider: provider)
        case .volcengineMT: return try await requestVolcengineMT(text: text, tgt: tgt, provider: provider)
        default:
            throw TranslationService.TranslationError.apiError("mtTranslate called for non-MT provider")
        }
    }

    // MARK: - Local Ollama fallback

    func resolveWithFallback(_ provider: APIProvider) async -> (APIProvider, Bool) {
        await FallbackRouter.resolveWithFallback(provider)
    }

    // MARK: - Private: stream dispatch

    private func performStream(
        text: String, sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage, provider: APIProvider,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        isDictionaryMode: Bool = false,
        context: CapturedContext? = nil
    ) async throws {
        switch provider.kind {
        case .openAI, .openAICompat:
            try await openAIStream(text, sourceLang, targetLang, provider, continuation, isDictionaryMode: isDictionaryMode, context: context)
        case .anthropic:
            try await anthropicStream(text, sourceLang, targetLang, provider, continuation, isDictionaryMode: isDictionaryMode, context: context)
        case .gemini:
            try await geminiStream(text, sourceLang, targetLang, provider, continuation, isDictionaryMode: isDictionaryMode, context: context)
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
        isDictionaryMode: Bool = false, context: CapturedContext? = nil
    ) async throws {
        let hint = isDictionaryMode ? buildDictionaryHint(tgt: tgt, context: context) : buildHint(src: src, tgt: tgt, context: context)
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
        if isDictionaryMode && p.kind == .openAICompat {
            body["response_format"] = ["type": "json_object"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = makeSession()
        let (bytes, resp) = try await session.bytes(for: req)
        try await validateSSEResponse(http: resp as? HTTPURLResponse, bytes: bytes) { data in
            (try? JSONDecoder().decode(OAIErr.self, from: data))?.error.message ?? "HTTP error"
        }

        let t = ThrottledStream(c)
        try await parseSSEStream(bytes: bytes, throttle: t) { (chunk: OAIStreamChunk) in
            chunk.choices?.first?.delta?.content
        }
        t.flush()
    }

    // ── Anthropic SSE ──

    private func anthropicStream(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, _ c: AsyncThrowingStream<String, Error>.Continuation,
        isDictionaryMode: Bool = false, context: CapturedContext? = nil
    ) async throws {
        let hint = isDictionaryMode ? buildDictionaryHint(tgt: tgt, context: context) : buildHint(src: src, tgt: tgt, context: context)
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
        try await validateSSEResponse(http: resp as? HTTPURLResponse, bytes: bytes) { data in
            (try? JSONDecoder().decode(AnthErr.self, from: data))?.error.message ?? "HTTP error"
        }

        let t = ThrottledStream(c)
        try await parseSSEStream(bytes: bytes, throttle: t) { (event: AnthStreamEvent) in
            event.type == "content_block_delta" ? event.delta?.text : nil
        }
        t.flush()
    }

    // ── Gemini SSE ──

    private func geminiStream(
        _ text: String, _ src: TranslationLanguage, _ tgt: TranslationLanguage,
        _ p: APIProvider, _ c: AsyncThrowingStream<String, Error>.Continuation,
        isDictionaryMode: Bool = false, context: CapturedContext? = nil
    ) async throws {
        let hint = isDictionaryMode ? buildDictionaryHint(tgt: tgt, context: context) : buildHint(src: src, tgt: tgt, context: context)
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
        try await validateSSEResponse(http: resp as? HTTPURLResponse, bytes: bytes) { data in
            (try? JSONDecoder().decode(GemErr.self, from: data))?.error.message ?? "HTTP error"
        }

        let t = ThrottledStream(c)
        try await parseSSEStream(bytes: bytes, throttle: t) { (chunk: GemStreamChunk) in
            chunk.candidates?.first?.content?.parts?.first?.text
        }
        t.flush()
    }

    // MARK: - Mock Stream (Traditional MT → single-token stream)

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
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "q": text,
            "target": tgt.languageCode.isEmpty ? "zh" : tgt.languageCode,
            "format": "text"
        ])

        let data = try await executeMTRequest(req, label: "Google MT")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let translations = dataDict["translations"] as? [[String: Any]],
              let first = translations.first?["translatedText"] as? String
        else { throw TranslationService.TranslationError.invalidResponse }
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
        req.httpBody = try JSONSerialization.data(withJSONObject: [["Text": text]])

        let data = try await executeMTRequest(req, label: "Bing MT")
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
        let urlString = "https://mt.cn-hangzhou.aliyuncs.com/?\(signedQuery)"
        print("[AlibabaMT] URL: \(urlString.prefix(200))...")
        guard let url = URL(string: urlString) else {
            throw TranslationService.TranslationError.malformedURL(provider.baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20

        let data = try await executeMTRequest(req, label: "Aliyun MT")
        let body = String(data: data, encoding: .utf8) ?? ""
        print("[AlibabaMT] body: \(body.prefix(300))")

        if let translated = body.extractXMLTag("Translated") { return translated }
        if let code = body.extractXMLTag("Code"), let msg = body.extractXMLTag("Message") {
            throw TranslationService.TranslationError.apiError("阿里云 [\(code)] \(msg)")
        }
        throw TranslationService.TranslationError.invalidResponse
    }

    // ── Volcengine MT (火山翻译) ──

    private func requestVolcengineMT(
        text: String, tgt: TranslationLanguage, provider: APIProvider
    ) async throws -> String {
        let key = provider.apiKey, secret = provider.apiSecret
        guard !key.isEmpty, !secret.isEmpty else {
            throw TranslationService.TranslationError.apiError("火山翻译需要 Access Key 和 Secret Key")
        }

        let tgtCode = tgt == .auto ? "zh" : tgt.languageCode
        let query = VolcengineSigner.signedQuery(
            accessKey: key, secretKey: secret,
            sourceText: text, sourceLanguage: "auto", targetLanguage: tgtCode
        )
        guard let url = URL(string: "https://translate.volcengineapi.com/?\(query)") else {
            throw TranslationService.TranslationError.malformedURL("https://translate.volcengineapi.com")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15

        let data = try await executeMTRequest(req, label: "Volcengine MT")
        let body = String(data: data, encoding: .utf8) ?? ""
        print("[VolcengineMT] body: \(body.prefix(300))")

        if let jsonData = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            if let list = json["TranslationList"] as? [[String: Any]],
               let first = list.first,
               let translated = first["Translation"] as? String {
                return translated.htmlEntityDecoded()
            }
            if let meta = json["ResponseMetadata"] as? [String: Any],
               let err = meta["Error"] as? [String: Any] {
                let code = err["Code"] as? String ?? "Unknown"
                let msg = err["Message"] as? String ?? "Unknown"
                throw TranslationService.TranslationError.apiError("火山翻译 [\(code)] \(msg)")
            }
        }
        throw TranslationService.TranslationError.invalidResponse
    }

    // MARK: - Helpers

    private func buildDictionaryHint(tgt: TranslationLanguage,
                                      context: CapturedContext? = nil) -> String {
        let langName = tgt.rawValue

        let baseHint = """
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

        // ── Dictionary context: force 300 chars regardless of intensity setting ──
        let ctxOn = UserDefaults.standard.bool(forKey: "is_context_aware")
        guard ctxOn, let ctx = context, ctx.hasContext else { return baseHint }

        let cap = 300
        let leading = String(ctx.leadingContext.suffix(cap))
        let trailing = String(ctx.trailingContext.prefix(cap))

        let contextInstruction = """


【重要语境优化指令】：
当前用户正在查阅词典，并提供了该单词/短语前后的上下文：
【上文】：\(leading)
【目标词汇】：\(ctx.selectedText)
【下文】：\(trailing)

请在生成的词典 JSON 响应中执行以下优化：
1. 审视上下文，判断当前语境下该词最精确的语义。
2. 在 "definitions"（释义列表）中，必须将最符合当前语境的解释与词性置于首位（Index 0），其他常规释义依次排在后面。
3. 在 "examples"（例句列表）中，第一条例句（Index 0）必须直接利用或高度契合当前的实际语境进行造句，以便用户快速理解该词在此处的用法。
"""

        return baseHint + contextInstruction
    }

    private func buildHint(src: TranslationLanguage, tgt: TranslationLanguage,
                           context: CapturedContext? = nil) -> String {
        let sourceName = src == .auto ? "Auto-Detected" : src.rawValue
        let targetName = tgt.rawValue

        let basePrompt: String
        if let data = UserDefaults.standard.data(forKey: "custom_prompt"),
           let cp = try? JSONDecoder().decode(CustomPrompt.self, from: data) {
            let raw = cp.enabled ? cp.text : CustomPrompt.defaultPrompt
            basePrompt = raw
                .replacingOccurrences(of: "__SOURCE_LANG__", with: sourceName)
                .replacingOccurrences(of: "__TARGET_LANG__", with: targetName)
        } else {
            basePrompt = CustomPrompt.defaultPrompt
                .replacingOccurrences(of: "__SOURCE_LANG__", with: sourceName)
                .replacingOccurrences(of: "__TARGET_LANG__", with: targetName)
        }

        // ── Inject bidirectional sliding-window context if available ──
        let augmentedPrompt = ContextAwareService.buildFinalPrompt(
            basePrompt: basePrompt, context: context
        )

        return augmentedPrompt + """


[CRITICAL FORMAT CONSTRAINT]
Translate directly. No introduction, no meta-commentary.
Preserve original formatting and Markdown tags if present.
"""
    }
}


// MARK: - SSE Throttle (80ms buffer)

/// Accumulates SSE tokens and flushes them to the continuation every ~80ms,
/// preventing SwiftUI from re-rendering on every single token.
private final class ThrottledStream {
    private var buffer = ""
    private var flushTask: Task<Void, Never>?
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let fastIntervalNs: UInt64  = 80_000_000   // 80ms — idle
    private let slowIntervalNs: UInt64  = 120_000_000  // 120ms — during window drag

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
            guard let self else { return }
            // Relax interval during window drag to avoid main-thread contention
            let isDragging = await MainActor.run { AppState.isUserDraggingWindow }
            let interval = isDragging ? self.slowIntervalNs : self.fastIntervalNs
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled, !self.buffer.isEmpty else { return }
            let text = self.buffer
            self.buffer = ""
            self.flushTask = nil
            self.continuation.yield(text)
        }
    }
}

// ── Inline response types ──

private struct OAIErr: Codable, Sendable {
    struct Detail: Codable, Sendable { let message: String }
    let error: Detail
}
private struct OAIStreamChunk: Codable, Sendable {
    struct Choice: Codable, Sendable { struct Delta: Codable, Sendable { let content: String? }; let delta: Delta? }
    let choices: [Choice]?
}
private struct AnthErr: Codable, Sendable {
    struct Detail: Codable, Sendable { let message: String }
    let error: Detail
}
private struct AnthStreamEvent: Codable, Sendable {
    struct Delta: Codable, Sendable { let text: String?; let type: String? }
    let type: String?; let delta: Delta?
}
private struct GemErr: Codable, Sendable {
    struct Detail: Codable, Sendable { let message: String }
    let error: Detail
}
private struct GemStreamChunk: Codable, Sendable {
    struct Cand: Codable, Sendable { struct Cont: Codable, Sendable { struct Part: Codable, Sendable { let text: String? }; let parts: [Part]? }; let content: Cont? }
    let candidates: [Cand]?
}

// MARK: - TranslationEngineProtocol conformance

extension TranslationActor: TranslationEngineProtocol {
    nonisolated func execute(
        text: String,
        provider: APIProvider,
        isDictionaryMode: Bool,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage,
        context: CapturedContext? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let actor = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                let stream: AsyncThrowingStream<String, Error>
                if isDictionaryMode && !provider.kind.isTraditionalMT && provider.kind != .macOSNative {
                    stream = await actor.translateDictionary(
                        text: text, sourceLang: sourceLang,
                        targetLang: targetLang, provider: provider, context: context
                    )
                } else {
                    stream = await actor.translateStream(
                        text: text, sourceLang: sourceLang,
                        targetLang: targetLang, provider: provider, context: context
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
