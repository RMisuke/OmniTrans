import Foundation

// MARK: - Type-Safe Request Models (M4)

/// Compile-time safe request bodies — eliminates `[String: Any]` + `JSONSerialization`
/// pattern that can only fail at runtime. Every model is `Encodable` so `JSONEncoder`
/// guarantees field names match exactly.

// MARK: OpenAI Chat Completion

struct OAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool
    let responseFormat: ResponseFormat?

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

// MARK: Anthropic Messages

struct AnthMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let temperature: Double
    let stream: Bool
    let system: String?
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model, temperature, stream, system, messages
        case maxTokens = "max_tokens"
    }
}

// MARK: Gemini Content Generation

struct GeminiRequest: Encodable {
    let contents: [Content]
    let generationConfig: GenerationConfig

    struct Content: Encodable {
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case maxOutputTokens = "maxOutputTokens"
        }
    }
}
