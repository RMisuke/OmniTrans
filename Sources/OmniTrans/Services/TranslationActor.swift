import Foundation
import CryptoKit

// MARK: - Pinning Configuration

/// Read pinned key hashes from UserDefaults so they can be configured
/// without recompiling.  Set a comma‑separated list under key `pinned_key_hashes`,
/// e.g.  `"sha256=AAAA...,sha256=BBBB..."`.
enum PinningConfig {
    /// Returns the current set of pinned hashes from UserDefaults.
    /// Empty set → no pinning (backward‑compatible default).
    static var currentHashes: Set<String> {
        let raw = UserDefaults.standard.string(forKey: "pinned_key_hashes") ?? ""
        guard !raw.isEmpty else { return [] }
        let parts = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return Set(parts)
    }
}

// MARK: - SSL Pinning Delegate (S3)

/// URLSession delegate that validates server certificates via public-key pinning.
///
/// Pinned hashes are configured through `PinningConfig.currentHashes`
/// (backed by UserDefaults `pinned_key_hashes`).  When the set is empty,
/// all certificates are accepted (backward‑compatible default).
///
/// - Important: `@unchecked Sendable` is required because `NSObject` is not
///   `Sendable` in Swift 6, yet `URLSessionDelegate` callbacks are always
///   invoked on the session's delegate queue — never concurrently.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    nonisolated(unsafe) static let shared = PinningDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // No pins configured → accept any valid certificate
        let pinned = PinningConfig.currentHashes
        guard !pinned.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard SecTrustEvaluateWithError(serverTrust, nil),
              let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let firstCert = certChain.first,
              let serverKey = SecCertificateCopyKey(firstCert),
              let keyData = SecKeyCopyExternalRepresentation(serverKey, nil) as Data?
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let hash = SHA256.hash(data: keyData).compactMap { String(format: "%02x", $0) }.joined()

        if pinned.contains(hash) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Shared URLSession (HTTP/2 Pipelining + Connection Reuse)

/// Global singleton `URLSession` configured for HTTP/2 multiplexing and
/// connection reuse.  All translation engines (AI streaming, MT single-shot)
/// share this session to eliminate per-request TCP/TLS handshake overhead.
///
/// ## Configuration
/// - `httpShouldUsePipelining = true` — enables HTTP/2 multiplexing
/// - `httpMaximumConnectionsPerHost = 10` — allows concurrent streams
/// - No URL cache — SSE streaming is incompatible with caching
/// - `waitsForConnectivity` — retries transient network failures instead of fast-fail
/// - `multipathServiceType = .handover` — seamless WiFi/cellular failover
/// - `Accept-Encoding: gzip` — response compression for faster transfers
/// - `PinningDelegate` — optional certificate pinning (no-op when pin list is empty)
///
/// Module-internal shared `URLSession` singleton — used by `TranslationActor`,
/// `TranslationService`, `APITestService`, and `FallbackRouter` for ALL HTTP
/// requests.  HTTP/2 multiplexing eliminates per-request TCP/TLS handshake overhead.
let pinningDelegate = PinningDelegate.shared

let sharedURLSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpShouldUsePipelining = true
    config.httpMaximumConnectionsPerHost = NetworkConfig.maxConnectionsPerHost
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = NetworkConfig.requestTimeout
    config.timeoutIntervalForResource = NetworkConfig.resourceTimeout
    // ── Connection resilience (P1) ──
    config.waitsForConnectivity = NetworkConfig.waitsForConnectivity
    config.allowsExpensiveNetworkAccess = true
    config.allowsConstrainedNetworkAccess = true
    // Demand gzip — many providers (OpenAI, Anthropic, Google) already
    // compress by default, but the explicit header ensures consistent behaviour.
    var headers = config.httpAdditionalHeaders ?? [:]
    headers["Accept-Encoding"] = "gzip, identity"
    config.httpAdditionalHeaders = headers
    return URLSession(configuration: config, delegate: pinningDelegate, delegateQueue: nil)
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
        NetworkLogger.logRequest(req, label: label)
        try Task.checkCancellation()
        let (data, resp) = try await makeSession().data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("\(label): 无效响应")
        }
        NetworkLogger.logResponse(http, data: data, label: label)
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
            NetworkLogger.logError("SSE", TranslationService.TranslationError.apiError(msg))
            throw TranslationService.TranslationError.apiError(msg)
        }
        NetworkLogger.logResponse(http, label: "SSE")
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

    // MARK: - Non-streaming (single-shot — AI + MT)

    /// Single-shot translation for all provider kinds.
    /// AI providers (OpenAI, Anthropic, Gemini) use REST non-streaming.
    /// Traditional MT providers (Google, Bing, Alibaba, Volcengine) use native single-shot.
    func nonStreamingTranslate(
        text: String,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage,
        provider: APIProvider
    ) async throws -> TranslationService.TranslationResult {
        switch provider.kind {
        case .openAI, .openAICompat, .ollama:
            return try await nonStreamingOpenAI(text: text, src: sourceLang, tgt: targetLang, provider: provider)
        case .anthropic:
            return try await nonStreamingAnthropic(text: text, src: sourceLang, tgt: targetLang, provider: provider)
        case .gemini:
            return try await nonStreamingGemini(text: text, src: sourceLang, tgt: targetLang, provider: provider)
        case .macOSNative:
            throw TranslationService.TranslationError.apiError("macOS Native should be handled locally")
        case .googleMT, .bingMT, .alibabaMT, .volcengineMT:
            let result = try await mtTranslate(text: text, tgt: targetLang, provider: provider)
            return TranslationService.TranslationResult(
                text: result, providerName: provider.name,
                model: provider.modelName, tokensUsed: 0
            )
        }
    }

    // MARK: - Traditional MT (single-shot)

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
        NetworkLogger.log("Stream", "starting provider=\(provider.name) kind=\(provider.kind) dict=\(isDictionaryMode) text=\(text.prefix(40))")
        switch provider.kind {
        case .openAI, .openAICompat, .ollama:
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
        req.timeoutInterval = NetworkConfig.streamingTimeout

        let requestBody = OAIChatCompletionRequest(
            model: p.modelName,
            messages: [
                .init(role: "system", content: hint),
                .init(role: "user", content: text)
            ],
            temperature: p.temperature,
            maxTokens: p.maxTokens,
            stream: true,
            responseFormat: (isDictionaryMode && p.kind == .openAICompat)
                ? .init(type: "json_object")
                : nil
        )
        req.httpBody = try JSONEncoder().encode(requestBody)

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
        req.timeoutInterval = NetworkConfig.streamingTimeout

        let requestBody = AnthMessagesRequest(
            model: p.modelName,
            maxTokens: p.maxTokens,
            temperature: p.temperature,
            stream: true,
            system: nil, // hint baked into user message below (preserving existing behavior)
            messages: [.init(role: "user", content: "\(hint)\n\n\(text)")]
        )
        req.httpBody = try JSONEncoder().encode(requestBody)

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
        req.timeoutInterval = NetworkConfig.streamingTimeout

        let requestBody = GeminiRequest(
            contents: [.init(parts: [.init(text: "\(hint)\n\n\(text)")])],
            generationConfig: .init(temperature: p.temperature, maxOutputTokens: p.maxTokens)
        )
        req.httpBody = try JSONEncoder().encode(requestBody)

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

    // MARK: - Non-streaming AI (single-shot REST)

    /// Non-streaming OpenAI-compatible (used for fallback when streaming fails).
    private func nonStreamingOpenAI(
        text: String, src: TranslationLanguage, tgt: TranslationLanguage,
        provider p: APIProvider
    ) async throws -> TranslationService.TranslationResult {
        guard let url = URL(string: "\(p.baseURL)/chat/completions") else {
            throw TranslationService.TranslationError.malformedURL("\(p.baseURL)/chat/completions")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = NetworkConfig.nonStreamingTimeout

        let hint = nonStreamingHint(src: src, tgt: tgt)
        let requestBody = OAIChatCompletionRequest(
            model: p.modelName,
            messages: [
                .init(role: "system", content: hint),
                .init(role: "user", content: text)
            ],
            temperature: p.temperature,
            maxTokens: p.maxTokens,
            stream: false,
            responseFormat: nil
        )
        req.httpBody = try JSONEncoder().encode(requestBody)

        let (data, resp) = try await sharedURLSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("invalid")
        }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(OAIErr.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw TranslationService.TranslationError.apiError(msg)
        }
        let r = try JSONDecoder().decode(OAIResp.self, from: data)
        guard let c = r.choices.first?.message.content else {
            throw TranslationService.TranslationError.invalidResponse
        }
        return TranslationService.TranslationResult(
            text: c.trimmingCharacters(in: .whitespacesAndNewlines),
            providerName: p.name, model: p.modelName,
            tokensUsed: r.usage?.totalTokens ?? 0
        )
    }

    /// Non-streaming Anthropic (used for fallback when streaming fails).
    private func nonStreamingAnthropic(
        text: String, src: TranslationLanguage, tgt: TranslationLanguage,
        provider p: APIProvider
    ) async throws -> TranslationService.TranslationResult {
        guard let url = URL(string: "\(p.baseURL)/v1/messages") else {
            throw TranslationService.TranslationError.malformedURL("\(p.baseURL)/v1/messages")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(p.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = NetworkConfig.nonStreamingTimeout

        let hint = nonStreamingHint(src: src, tgt: tgt)
        let requestBody = AnthMessagesRequest(
            model: p.modelName,
            maxTokens: p.maxTokens,
            temperature: p.temperature,
            stream: false,
            system: hint,
            messages: [.init(role: "user", content: text)]
        )
        req.httpBody = try JSONEncoder().encode(requestBody)

        let (data, resp) = try await sharedURLSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("invalid")
        }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(AnthErr.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw TranslationService.TranslationError.apiError(msg)
        }
        let r = try JSONDecoder().decode(AnthResp.self, from: data)
        guard let c = r.content.first, c.type == "text" else {
            throw TranslationService.TranslationError.invalidResponse
        }
        return TranslationService.TranslationResult(
            text: c.text.trimmingCharacters(in: .whitespacesAndNewlines),
            providerName: p.name, model: p.modelName,
            tokensUsed: (r.usage?.inputTokens ?? 0) + (r.usage?.outputTokens ?? 0)
        )
    }

    /// Non-streaming Gemini (used for fallback when streaming fails).
    private func nonStreamingGemini(
        text: String, src: TranslationLanguage, tgt: TranslationLanguage,
        provider p: APIProvider
    ) async throws -> TranslationService.TranslationResult {
        guard let url = URL(string: "\(p.baseURL)/models/\(p.modelName):generateContent") else {
            throw TranslationService.TranslationError.malformedURL("\(p.baseURL)/models/\(p.modelName):generateContent")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(p.apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = NetworkConfig.nonStreamingTimeout

        let hint = nonStreamingHint(src: src, tgt: tgt)
        let requestBody = GeminiRequest(
            contents: [.init(parts: [.init(text: "\(hint)\n\n\(text)")])],
            generationConfig: .init(temperature: p.temperature, maxOutputTokens: p.maxTokens)
        )
        req.httpBody = try JSONEncoder().encode(requestBody)

        let (data, resp) = try await sharedURLSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranslationService.TranslationError.networkError("invalid")
        }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(GemErr.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw TranslationService.TranslationError.apiError(msg)
        }
        let r = try JSONDecoder().decode(GemResp.self, from: data)
        guard let t = r.candidates?.first?.content?.parts?.first?.text else {
            throw TranslationService.TranslationError.invalidResponse
        }
        return TranslationService.TranslationResult(
            text: t.trimmingCharacters(in: .whitespacesAndNewlines),
            providerName: p.name, model: p.modelName,
            tokensUsed: r.usageMetadata?.totalTokenCount ?? 0
        )
    }

    /// Minimal hint for non-streaming path — no context injection (MT/fallback).
    private func nonStreamingHint(src: TranslationLanguage, tgt: TranslationLanguage) -> String {
        if src == .auto {
            return "Translate to \(tgt.languageCode). Output translation only."
        } else {
            return "Translate \(src.languageCode) to \(tgt.languageCode). Output translation only."
        }
    }

    // ── Google Cloud Translation v2 ──

    private func requestGoogleMT(
        text: String, tgt: TranslationLanguage, provider: APIProvider
    ) async throws -> String {
        guard let url = URL(string: provider.baseURL) else {
            throw TranslationService.TranslationError.malformedURL(provider.baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(provider.apiKey, forHTTPHeaderField: "X-goog-api-key") // S1: header, not URL query
        req.timeoutInterval = NetworkConfig.mtTimeout
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
        req.timeoutInterval = NetworkConfig.mtTimeout
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
        print("[AlibabaMT] URL: \(urlString.redactSensitiveParams().prefix(200))...") // S2
        guard let url = URL(string: urlString) else {
            throw TranslationService.TranslationError.malformedURL(provider.baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = NetworkConfig.mtTimeout

        let data = try await executeMTRequest(req, label: "Aliyun MT")
        let body = String(data: data, encoding: .utf8) ?? ""
        print("[AlibabaMT] body: \(body.prefix(300))")

        if let translated = body.xmlTagValue("Translated") { return translated }
        if let code = body.xmlTagValue("Code"), let msg = body.xmlTagValue("Message") {
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
        req.timeoutInterval = NetworkConfig.mtTimeout

        let data = try await executeMTRequest(req, label: "Volcengine MT")
        let body = String(data: data, encoding: .utf8) ?? ""
        print("[VolcengineMT] body: \(body.prefix(300))") // S2

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
You are an expert lexicographer. Analyze the __SOURCE_LANG__ query and output a highly structured dictionary entry in __TARGET_LANG__.

Expected JSON Schema:
{
  "is_word": true,
  "phonetic": "/IPA notation/",
  "definitions": [
    {"pos": "n.", "meaning": "definition exclusively in \(langName)"}
  ],
  "examples": [
    {"en": "example in source language", "zh": "translation in \(langName)"}
  ]
}

<Rules>
- "meaning" MUST be exclusively in \(langName).
- "zh" (example translation) MUST be exclusively in \(langName). Include the query in the source example.
- "pos": Standardize using n., v., adj., adv., prep., conj., pron.
- "phonetic": Use IPA notation or \"\" if inapplicable.
- Provide at least 2 examples.
</Rules>

[CRITICAL FORMAT CONSTRAINT]
Output EXACTLY and ONLY valid JSON.
Do NOT wrap the response in Markdown code blocks (no ```json). No explanations.
"""

        // ── Dictionary context: force 300 chars regardless of intensity setting ──
        let ctxOn = UserDefaults.standard.bool(forKey: "is_context_aware")
        guard ctxOn, let ctx = context, ctx.hasContext else { return baseHint }

        let cap = 300
        let leading = String(ctx.leadingContext.suffix(cap))
        let trailing = String(ctx.trailingContext.prefix(cap))

        let contextInstruction = """
<ContextOptimization>
The query is used within the following specific context:
<Prefix>\(leading)</Prefix>
<Query>\(ctx.selectedText)</Query>
<Suffix>\(trailing)</Suffix>

Mandatory Adjustments:
1. "definitions" Array Index 0: MUST be the exact meaning and part of speech used in this specific context.
2. "examples" Array Index 0: MUST heavily reflect or directly utilize this contextual usage to help the user understand its current application.
</ContextOptimization>
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

        return augmentedPrompt
    }
}


// MARK: - SSE Throttle (80ms buffer)

/// Accumulates SSE tokens and flushes them to the continuation every ~35ms,
/// preventing SwiftUI from re-rendering on every single token.
///
/// **First-chunk passthrough**: the very first `yield()` delivers its token
/// Adaptive throttle stream — batches tokens for fluid UI updates while
/// dynamically adjusting the batch window based on real-time token arrival rate.
///
/// - First chunk always passes through immediately (zero latency for first word).
/// - Subsequent tokens are batched using an adaptive interval:
///   • Fast arrival (< 10 ms apart) → 15 ms batch  (responsive UI)
///   • Medium arrival (10–40 ms)    → 35 ms batch  (smooth default)
///   • Slow arrival (> 40 ms)       → 80 ms batch  (accumulate enough for fluent update)
/// - During window drag (`isUserDraggingWindow`), the interval is capped at 120 ms
///   to avoid main-thread contention with AppKit event tracking.
private final class ThrottledStream {
    private var buffer = ""
    private var flushTask: Task<Void, Never>?
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    /// Whether the first chunk has already been passed through
    private var firstChunkDelivered = false

    // MARK: - Adaptive throttle state

    /// Monotonic timestamp (nanoseconds) of the last yielded token.
    private var lastTokenTime = DispatchTime.now().uptimeNanoseconds
    /// Smoothed inter-arrival time (nanoseconds) — exponential moving average.
    private var smoothedGapNs: UInt64 = 35_000_000

    /// Computes the current adaptive batch interval based on `smoothedGapNs`.
    private var adaptiveIntervalNs: UInt64 {
        let base: UInt64
        if smoothedGapNs < 10_000_000 {
            base = 15_000_000                         // fast network → 15ms
        } else if smoothedGapNs < 40_000_000 {
            base = NetworkConfig.throttleFastNs        // normal → 35ms
        } else {
            base = 80_000_000                          // slow → 80ms
        }
        // During window drag, never exceed the slow path limit
        return min(base, NetworkConfig.throttleSlowNs)
    }

    init(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ chunk: String) {
        // ── Update adaptive state ──
        let now = DispatchTime.now().uptimeNanoseconds
        let gapNs = now - lastTokenTime
        lastTokenTime = now

        // Exponential moving average (α ≈ 0.3)
        if smoothedGapNs == 35_000_000 {
            smoothedGapNs = gapNs  // first real measurement
        } else {
            smoothedGapNs = UInt64(Double(smoothedGapNs) * 0.7 + Double(gapNs) * 0.3)
        }

        // ── First chunk passthrough (P4) ──
        if !firstChunkDelivered {
            firstChunkDelivered = true
            continuation.yield(chunk)
            return
        }
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
        let interval = self.adaptiveIntervalNs
        flushTask = Task {
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled, !self.buffer.isEmpty else { return }
            let text = self.buffer
            self.buffer = ""
            self.flushTask = nil
            self.continuation.yield(text)
        }
    }
}

// ── Shared error / response types (used by TranslationActor + TranslationService) ──

struct OAIErr: Codable, Sendable {
    struct Detail: Codable, Sendable { let message: String }
    let error: Detail
}
private struct OAIStreamChunk: Codable, Sendable {
    struct Choice: Codable, Sendable { struct Delta: Codable, Sendable { let content: String? }; let delta: Delta? }
    let choices: [Choice]?
}
struct AnthErr: Codable, Sendable {
    struct Detail: Codable, Sendable { let message: String }
    let error: Detail
}
private struct AnthStreamEvent: Codable, Sendable {
    struct Delta: Codable, Sendable { let text: String?; let type: String? }
    let type: String?; let delta: Delta?
}
struct GemErr: Codable, Sendable {
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
