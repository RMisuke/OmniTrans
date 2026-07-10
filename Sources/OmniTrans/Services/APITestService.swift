import Foundation

enum APITestService {
    enum TestResult {
        case success(latency: Double)
        case failure(String)
    }

    enum ModelListResult {
        case success([String])
        case failure(String)
    }

    // MARK: - Connection Test

    static func testConnection(for provider: APIProvider) async -> TestResult {
        let start = Date()
        do {
            switch provider.kind {
            case .openAI, .openAICompat, .ollama:
                try await testOpenAI(provider: provider)
            case .anthropic:
                try await testAnthropic(provider: provider)
            case .gemini:
                try await testGoogle(provider: provider)
            case .macOSNative:
                break // local, always available
            case .googleMT:
                try await testGoogleMT(provider: provider)
            case .bingMT:
                try await testBingMT(provider: provider)
            case .alibabaMT:
                try await testAlibabaMT(provider: provider)
            case .volcengineMT:
                try await testVolcengineMT(provider: provider)
            }
            let latency = Date().timeIntervalSince(start)
            return .success(latency: latency)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Fetch Models

    static func fetchModels(for provider: APIProvider) async -> ModelListResult {
        do {
            switch provider.kind {
            case .openAI, .openAICompat, .ollama:
                return try await fetchOpenAIModels(provider: provider)
            case .anthropic:
                return try await fetchAnthropicModels(provider: provider)
            case .gemini:
                return try await fetchGoogleModels(provider: provider)
            case .macOSNative:
                return .success(["macOS Dictionary + Translation"])
            case .googleMT:
                return .success(["nmt"])
            case .bingMT:
                return .success(["general"])
            case .alibabaMT:
                return .success(["general"])
            case .volcengineMT:
                return .success(["general"])
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Private: OpenAI-compatible models

    private static func fetchOpenAIModels(provider: APIProvider) async throws -> ModelListResult {
        guard let url = URL(string: "\(provider.baseURL)/models") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = NetworkConfig.modelFetchTimeout

        let (data, response) = try await sharedURLSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"]) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        // OpenAI models API returns { "data": [{"id": "model-name", ...}, ...] }
        struct ModelsResponse: Codable {
            struct Model: Codable { let id: String }
            let data: [Model]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return .success(decoded.data.map(\.id).sorted())
    }

    // MARK: - Private: Anthropic

    private static func fetchAnthropicModels(provider: APIProvider) async throws -> ModelListResult {
        // Anthropic doesn't have a public models list endpoint; return popular ones
        return .success([
            "claude-3-5-sonnet-20241022",
            "claude-3-opus-20240229",
            "claude-3-sonnet-20240229",
            "claude-3-haiku-20240307"
        ])
    }

    // MARK: - Private: Google

    private static func fetchGoogleModels(provider: APIProvider) async throws -> ModelListResult {
        guard let url = URL(string: "\(provider.baseURL)/models") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }
        var request = URLRequest(url: url)
        request.setValue(provider.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = NetworkConfig.modelFetchTimeout

        let (data, response) = try await sharedURLSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"]) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        // Gemini models response: { "models": [{"name": "models/gemini-pro", ...}, ...] }
        struct GeminiModelsResponse: Codable {
            struct Model: Codable { let name: String }
            let models: [Model]?
        }

        let decoded = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        let names = (decoded.models ?? []).map { $0.name.replacingOccurrences(of: "models/", with: "") }.sorted()
        return .success(names.isEmpty ? ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash"] : names)
    }

    /// Shared timeout (seconds) for all connectivity probes.
    /// 3 s is enough for TLS handshake + headers on modern CDN-backed APIs,
    /// while failing fast enough to keep the indicator responsive.
    private static let probeTimeout: TimeInterval = NetworkConfig.probeTimeout

    /// Extracts a human-readable error message from a JSON error body
    /// (OpenAI / Anthropic / Google formats).  Falls back to raw HTTP status.
    private static func parseErrorBody(_ data: Data, statusCode: Int) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "HTTP \(statusCode)"
        }
        // OpenAI / Anthropic: {"error": {"message": "..."}}
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        // Google: {"error": {"message": "..."}}  or  {"error": {"code": ..., "message": "..."}}
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        // Generic: any "message" key at top level
        if let msg = json["message"] as? String { return msg }
        return "HTTP \(statusCode)"
    }

    /// Validates an HTTP response.  Throws with a parsed error message
    /// for any status outside 200…299.
    private static func validateProbeResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"])
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = parseErrorBody(data, statusCode: http.statusCode)
            throw NSError(domain: "", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - Private: Test helpers

    private static func testOpenAI(provider: APIProvider) async throws {
        guard let url = URL(string: "\(provider.baseURL)/models") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = probeTimeout
        let (data, response) = try await sharedURLSession.data(for: request)
        try validateProbeResponse(data: data, response: response)
    }

    private static func testAnthropic(provider: APIProvider) async throws {
        guard let url = URL(string: "\(provider.baseURL)/v1/messages") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = probeTimeout
        let body: [String: Any] = ["model": provider.modelName, "max_tokens": 10, "messages": [["role": "user", "content": "hi"]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await sharedURLSession.data(for: request)
        try validateProbeResponse(data: data, response: response)
    }

    private static func testGoogle(provider: APIProvider) async throws {
        guard let url = URL(string: "\(provider.baseURL)/models") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.setValue(provider.apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await sharedURLSession.data(for: request)
        try validateProbeResponse(data: data, response: response)
    }

    // MARK: - Private: MT test helpers

    private static func testGoogleMT(provider: APIProvider) async throws {
        guard let url = URL(string: provider.baseURL) else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效地址"]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(provider.apiKey, forHTTPHeaderField: "X-goog-api-key") // S1: header, not URL query
        req.timeoutInterval = probeTimeout
        let body: [String: Any] = ["q": "test", "target": "zh", "format": "text"]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await sharedURLSession.data(for: req)
        try validateProbeResponse(data: data, response: resp)
    }

    private static func testBingMT(provider: APIProvider) async throws {
        let region = provider.customRegion.isEmpty ? "global" : provider.customRegion
        guard let url = URL(string: "\(provider.baseURL)/languages?api-version=3.0") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效地址"])
        }
        var req = URLRequest(url: url)
        req.setValue(provider.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        req.timeoutInterval = probeTimeout
        let (data, resp) = try await sharedURLSession.data(for: req)
        try validateProbeResponse(data: data, response: resp)
    }

    private static func testAlibabaMT(provider: APIProvider) async throws {
        // Use a real signed API call to verify credentials
        try await AlibabaCloudSigner.testConnectivity(
            accessKeyId: provider.apiKey,
            accessKeySecret: provider.apiSecret
        )
    }

    private static func testVolcengineMT(provider: APIProvider) async throws {
        try await VolcengineSigner.testConnectivity(
            accessKey: provider.apiKey,
            secretKey: provider.apiSecret
        )
    }
}

