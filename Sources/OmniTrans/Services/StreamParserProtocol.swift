import Foundation

// MARK: - Stream Parser Protocol

/// Abstracts SSE chunk deserialization so each provider can supply its own parser.
/// Keeps TranslationActor free of provider-specific JSON decoding logic.
protocol StreamParserProtocol {
    /// Extract displayable text from a raw SSE data chunk.
    /// Returns nil if the chunk contains no text (e.g. heartbeat, metadata).
    func parse(chunk: Data) throws -> String?
}

// MARK: - OpenAI / OpenAI-compatible Parser

struct OpenAIStreamParser: StreamParserProtocol {
    func parse(chunk: Data) throws -> String? {
        guard let line = String(data: chunk, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              line.hasPrefix("data: "), !line.hasPrefix("data: [DONE]")
        else { return nil }

        let jsonStr = String(line.dropFirst(6))
        guard let jsonData = jsonStr.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OAIStreamChunk.self, from: jsonData)
        else { return nil }

        return decoded.choices?.first?.delta?.content
    }
}

// MARK: - Anthropic Parser

struct AnthropicStreamParser: StreamParserProtocol {
    func parse(chunk: Data) throws -> String? {
        guard let line = String(data: chunk, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              line.hasPrefix("data: ")
        else { return nil }

        let jsonStr = String(line.dropFirst(6))
        guard let jsonData = jsonStr.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AnthStreamEvent.self, from: jsonData)
        else { return nil }

        if decoded.type == "content_block_delta",
           decoded.delta?.type == "text_delta",
           let text = decoded.delta?.text {
            return text
        }
        return nil
    }
}

// MARK: - Gemini Parser

struct GeminiStreamParser: StreamParserProtocol {
    func parse(chunk: Data) throws -> String? {
        guard let line = String(data: chunk, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              line.hasPrefix("data: ")
        else { return nil }

        let jsonStr = String(line.dropFirst(6))
        guard let jsonData = jsonStr.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GemStreamChunk.self, from: jsonData)
        else { return nil }

        return decoded.candidates?.first?.content?.parts?.first?.text
    }
}

// MARK: - Parser Factory

enum StreamParserFactory {
    static func parser(for kind: ProviderKind) -> StreamParserProtocol? {
        switch kind {
        case .openAI, .openAICompat:
            return OpenAIStreamParser()
        case .anthropic:
            return AnthropicStreamParser()
        case .gemini:
            return GeminiStreamParser()
        default:
            return nil  // MT / Native don't use SSE
        }
    }
}

// ── Lightweight decodable types for stream parsing ──

private struct OAIStreamChunk: Codable {
    struct Choice: Codable { struct Delta: Codable { let content: String? }; let delta: Delta? }
    let choices: [Choice]?
}

private struct AnthStreamEvent: Codable {
    struct Delta: Codable { let text: String?; let type: String? }
    let type: String?; let delta: Delta?
}

private struct GemStreamChunk: Codable {
    struct Cand: Codable { struct Cont: Codable { struct Part: Codable { let text: String? }; let parts: [Part]? }; let content: Cont? }
    let candidates: [Cand]?
}
