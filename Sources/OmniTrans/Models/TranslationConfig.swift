import Foundation

/// Supported languages for translation
enum TranslationLanguage: String, CaseIterable, Identifiable, Codable {
    case auto     = "自动检测"
    case chinese  = "中文"
    case english  = "English"
    case japanese = "日本語"
    case korean   = "한국어"
    case french   = "Français"
    case german   = "Deutsch"
    case spanish  = "Español"
    case russian  = "Русский"
    case portuguese = "Português"
    case italian  = "Italiano"
    case arabic   = "العربية"
    case thai     = "ไทย"
    case vietnamese = "Tiếng Việt"

    var id: String { rawValue }

    /// ISO 639-1 / BCP-47 language code for LLM prompts
    var languageCode: String {
        switch self {
        case .auto:     return ""
        case .chinese:  return "zh"
        case .english:  return "en"
        case .japanese: return "ja"
        case .korean:   return "ko"
        case .french:   return "fr"
        case .german:   return "de"
        case .spanish:  return "es"
        case .russian:  return "ru"
        case .portuguese: return "pt"
        case .italian:  return "it"
        case .arabic:   return "ar"
        case .thai:     return "th"
        case .vietnamese: return "vi"
        }
    }

    /// Bridges to `Locale.Language` for the system Translation framework.
    @available(macOS 15.0, *)
    var systemLocaleLanguage: Locale.Language {
        switch self {
        case .auto:       return Locale.Language(identifier: "en")
        case .chinese:    return Locale.Language(identifier: "zh-Hans")
        case .english:    return Locale.Language(identifier: "en")
        case .japanese:   return Locale.Language(identifier: "ja")
        case .korean:     return Locale.Language(identifier: "ko")
        case .french:     return Locale.Language(identifier: "fr")
        case .german:     return Locale.Language(identifier: "de")
        case .spanish:    return Locale.Language(identifier: "es")
        case .russian:    return Locale.Language(identifier: "ru")
        case .portuguese: return Locale.Language(identifier: "pt")
        case .italian:    return Locale.Language(identifier: "it")
        case .arabic:     return Locale.Language(identifier: "ar")
        case .thai:       return Locale.Language(identifier: "th")
        case .vietnamese: return Locale.Language(identifier: "vi")
        }
    }
}
