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
    var isFromLocalCache: Bool = false
    var cachedModelName: String = ""
    var cacheTimestamp: String = ""

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
            UserDefaults.standard.bool(forKey: "is_context_aware")
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
            UserDefaults.standard.integer(forKey: "context_intensity")
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
            UserDefaults.standard.bool(forKey: "cache_enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "cache_enabled")
        }
    }

    /// Whether the personal dictionary cache is enabled.
    /// When `true`, dictionary lookups first check the local SQLite database
    /// before making an LLM API call.  Entries are write-once — only a user
    /// initiated re‑lookup (`forceRefresh`) overwrites them.
    /// Defaults to `true`.
    var isDictCacheEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: "dict_cache_enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "dict_cache_enabled")
        }
    }

    /// Context capture character limit derived from `contextIntensity`.
    /// Delegates to `ContextAwareService` — the single source of truth for
    /// the intensity→character mapping, avoiding duplicate switch logic.
    var contextCharLimit: Int {
        ContextAwareService.contextCharLimit
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

    // MARK: - Defaults Registration

    /// Registers all default values with `UserDefaults` — must be called
    /// **exactly once** during app launch (e.g. from `AppDelegate`).
    ///
    /// `register(defaults:)` only sets values that have never been written,
    /// so repeated calls are harmless but wasteful — this method centralises
    /// all defaults so the per-property `register(defaults:)` calls are
    /// removed from the computed getters above.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "is_context_aware": true,
            "context_intensity": 2,
            "cache_enabled": true,
            "dict_cache_enabled": true,
            "hotkeys_enabled": true,
        ])
    }
}

// MARK: - Legacy aliases (kept for existing @Observable usage)

/// Previously `UIStateStore` — kept as typealias for source compatibility.
typealias UIStateStore = TranslationSessionStore

/// Previously `SettingsStore` — kept as typealias for source compatibility.
typealias SettingsStore = ConfigurationStore
