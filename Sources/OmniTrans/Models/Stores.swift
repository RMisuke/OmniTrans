import SwiftUI
import Observation

// MARK: - Translation Session Store

/// High-frequency streaming state — isolated into a dedicated @Observable
/// store so that SwiftUI field-level observation only triggers local body
/// recomputation inside views that actually render translated text.
///
/// Views that only need config / providers should observe `ConfigurationStore`
/// (or legacy `AppState`), not this store.
@Observable
final class TranslationSessionStore {
    var translatedText: String = ""
    var isTranslating: Bool = false
    var streamingFinished: Bool = false
    var inputText: String = ""
    var showSuccessPulse: Bool = false
    var errorMessage: String? = nil
    var showErrorShake: Bool = false
    var showErrorPulse: Bool = false
    var isDictionaryMode: Bool = false
    var dictionaryEntry: DictionaryEntry? = nil
    var detectedIsWord: Bool = false
    var showPermissionHint: Bool = false

    /// The last successfully parsed dictionary JSON string.  Used by the
    /// menu bar `TranslationView` as a "hard lock" fallback — when
    /// streaming tail frames overwrite `translatedText` with empty / non‑JSON
    /// content, the view falls back to this cached value so the rendered
    /// dictionary layout never collapses to a blank area.
    var lastValidDictionaryJson: String? = nil
}

// MARK: - Configuration Store

/// Provider config, language preferences, history — low-frequency state
/// that does NOT change during streaming translation.
@Observable
final class ConfigurationStore {
    var providers: [APIProvider] = []
    var selectedProviderID: UUID? = nil
    var dictProviderID: UUID? = nil
    var sourceLang: TranslationLanguage = .auto
    var targetLang: TranslationLanguage = .chinese
    var translationHistory: [HistoryEntry] = []

    /// Context-aware translation toggle — persisted to UserDefaults.
    /// When enabled, the app injects bidirectional sliding-window context
    /// into the LLM prompt for domain-appropriate translations (pronoun
    /// resolution, terminology, tonal consistency).  Defaults to `true`.
    var isContextAwareEnabled: Bool {
        get {
            UserDefaults.standard.register(defaults: ["is_context_aware": true])
            return UserDefaults.standard.bool(forKey: "is_context_aware")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "is_context_aware")
        }
    }

    /// Context intensity level (0–4).  Controls the sliding-window capture
    /// radius in 5 fine-grained tiers:
    ///   0 → 100, 1 → 200, 2 → 300 (default), 3 → 400, 4 → 500.
    /// Higher levels improve terminology accuracy but increase Token cost.
    var contextIntensity: Int {
        get {
            UserDefaults.standard.register(defaults: ["context_intensity": 2])
            return UserDefaults.standard.integer(forKey: "context_intensity")
        }
        set {
            UserDefaults.standard.set(max(0, min(4, newValue)), forKey: "context_intensity")
        }
    }

    /// Whether the local translation cache is enabled.
    /// When `false`, every translation request bypasses the in-memory cache
    /// and hits the network / engine directly.  Defaults to `true`.
    var isCacheEnabled: Bool {
        get {
            UserDefaults.standard.register(defaults: ["cache_enabled": true])
            return UserDefaults.standard.bool(forKey: "cache_enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "cache_enabled")
        }
    }

    /// Context capture character limit derived from `contextIntensity`.
    var contextCharLimit: Int {
        switch contextIntensity {
        case 0: return 100
        case 1: return 200
        case 3: return 400
        case 4: return 500
        default: return 300
        }
    }

    /// Bridge from legacy AppState on launch / settings changes.
    @MainActor func syncFrom(_ state: AppState) {
        providers = state.providers
        selectedProviderID = state.selectedProviderID
        dictProviderID = state.dictProviderID
        sourceLang = state.sourceLang
        targetLang = state.targetLang
        translationHistory = state.translationHistory
    }
}

// MARK: - Legacy aliases (kept for existing @Observable usage)

/// Previously `UIStateStore` — kept as typealias for source compatibility.
typealias UIStateStore = TranslationSessionStore

/// Previously `SettingsStore` — kept as typealias for source compatibility.
typealias SettingsStore = ConfigurationStore
