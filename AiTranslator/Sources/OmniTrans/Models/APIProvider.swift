import Foundation

/// Simplified provider type — all use OpenAI chat-completions protocol
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAI     = "OpenAI"
    case openAICompat = "OpenAI 兼容"
    case anthropic  = "Claude"
    case gemini     = "Gemini"

    var id: String { rawValue }

    var defaultBaseURL: String {
        switch self {
        case .openAI:       return "https://api.openai.com/v1"
        case .openAICompat:  return "https://api.openai.com/v1"
        case .anthropic:     return "https://api.anthropic.com"
        case .gemini:        return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:       return "gpt-4o-mini"
        case .openAICompat:  return "gpt-4o"
        case .anthropic:     return "claude-3-haiku-20240307"
        case .gemini:        return "gemini-2.0-flash"
        }
    }
}

struct APIProvider: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = ""
    var kind: ProviderKind = .openAI
    var baseURL: String = ""
    var apiKey: String = ""       // in-memory only, persisted to Keychain
    var modelName: String = ""
    var temperature: Double = 0.3
    var maxTokens: Int = 1024
    var isEnabled: Bool = true

    /// Factory
    static func blank(kind: ProviderKind = .openAI) -> APIProvider {
        var p = APIProvider()
        p.kind = kind
        p.baseURL = kind.defaultBaseURL
        p.modelName = kind.defaultModel
        return p
    }
}
