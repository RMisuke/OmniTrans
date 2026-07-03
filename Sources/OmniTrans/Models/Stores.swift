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
