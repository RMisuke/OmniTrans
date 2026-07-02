import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAI     = "OpenAI"
    case openAICompat = "OpenAI 兼容"
    case anthropic  = "Claude"
    case gemini     = "Gemini"
    case macOSNative = "macOS 原生"
    case googleMT   = "Google 翻译"
    case bingMT     = "Bing 翻译"
    case alibabaMT  = "阿里云翻译"
    case volcengineMT = "火山翻译"

    var id: String { rawValue }

    /// Whether this kind is a traditional (non-streaming) machine translation API.
    var isTraditionalMT: Bool {
        switch self {
        case .googleMT, .bingMT, .alibabaMT, .volcengineMT: return true
        default: return false
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:       return "https://api.openai.com/v1"
        case .openAICompat:  return "https://api.openai.com/v1"
        case .anthropic:     return "https://api.anthropic.com"
        case .gemini:        return "https://generativelanguage.googleapis.com/v1beta"
        case .macOSNative:   return ""
        case .googleMT:      return "https://translation.googleapis.com/language/translate/v2"
        case .bingMT:        return "https://api.cognitive.microsofttranslator.com"
        case .alibabaMT:     return "https://mt.cn-hangzhou.aliyuncs.com"
        case .volcengineMT:  return "https://translate.volcengineapi.com"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:       return "gpt-4o-mini"
        case .openAICompat:  return "gpt-4o"
        case .anthropic:     return "claude-3-haiku-20240307"
        case .gemini:        return "gemini-2.0-flash"
        case .macOSNative:   return "macOS Dictionary + Translation"
        case .googleMT:      return "nmt"
        case .bingMT:        return "general"
        case .alibabaMT:     return "general"
        case .volcengineMT:  return "general"
        }
    }
}

struct APIProvider: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = ""
    var kind: ProviderKind = .openAI
    var baseURL: String = ""
    var apiKey: String = ""
    var apiSecret: String = ""
    var customRegion: String = ""
    var modelName: String = ""
    var temperature: Double = 0.3
    var maxTokens: Int = 1024
    var isEnabled: Bool = true

    /// Built‑in providers cannot be deleted or edited.
    var isBuiltIn: Bool { kind == .macOSNative }

    static func blank(kind: ProviderKind = .openAI) -> APIProvider {
        var p = APIProvider()
        p.kind = kind
        p.baseURL = kind.defaultBaseURL
        p.modelName = kind.defaultModel
        return p
    }

    /// Immutable built‑in macOS native provider.
    static let native = APIProvider(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "macOS 原生（离线）",
        kind: .macOSNative,
        baseURL: "",
        apiKey: "",
        apiSecret: "",
        customRegion: "",
        modelName: "系统词典 + Translation",
        temperature: 0,
        maxTokens: 4096,
        isEnabled: true
    )
}
