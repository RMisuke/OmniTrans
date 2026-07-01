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
            case .openAI, .openAICompat:
                try await testOpenAI(provider: provider)
            case .anthropic:
                try await testAnthropic(provider: provider)
            case .gemini:
                try await testGoogle(provider: provider)
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
            case .openAI, .openAICompat:
                return try await fetchOpenAIModels(provider: provider)
            case .anthropic:
                return try await fetchAnthropicModels(provider: provider)
            case .gemini:
                return try await fetchGoogleModels(provider: provider)
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
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
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
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
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

    // MARK: - Private: Test helpers

    private static func testOpenAI(provider: APIProvider) async throws {
        guard let url = URL(string: "\(provider.baseURL)/models") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"]) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        _ = try JSONSerialization.jsonObject(with: data)
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
        request.timeoutInterval = 15
        let body: [String: Any] = ["model": provider.modelName, "max_tokens": 10, "messages": [["role": "user", "content": "hi"]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"]) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        _ = try JSONSerialization.jsonObject(with: data)
    }

    private static func testGoogle(provider: APIProvider) async throws {
        guard let url = URL(string: "\(provider.baseURL)/models") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(provider.apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"]) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        _ = try JSONSerialization.jsonObject(with: data)
    }
}
