import SwiftUI
import Observation

// MARK: - UI State Store

/// Reactive UI-level state: input, panel visibility, animations, word detection.
@Observable
final class UIStateStore {
    var inputText: String = ""
    var translatedText: String = ""
    var isTranslating: Bool = false
    var streamingFinished: Bool = false
    var detectedIsWord: Bool = false
    var isDictionaryMode: Bool = false
    var dictionaryEntry: DictionaryEntry? = nil
    var errorMessage: String? = nil
    var showPermissionHint: Bool = false
    var showSuccessPulse: Bool = false
    var showErrorShake: Bool = false

    /// Bridge to legacy AppState — reads are synced on access.
    @MainActor func syncFrom(_ state: AppState) {
        inputText = state.inputText
        translatedText = state.translatedText
        isTranslating = state.isTranslating
        streamingFinished = state.streamingFinished
        detectedIsWord = state.detectedIsWord
        isDictionaryMode = state.isDictionaryMode
        dictionaryEntry = state.dictionaryEntry
        errorMessage = state.errorMessage
        showPermissionHint = state.showPermissionHint
        showSuccessPulse = state.showSuccessPulse
        showErrorShake = state.showErrorShake
    }
}

// MARK: - Settings Store

/// Provider config, language preferences, history management.
@Observable
final class SettingsStore {
    var providers: [APIProvider] = []
    var selectedProviderID: UUID? = nil
    var dictProviderID: UUID? = nil
    var sourceLang: TranslationLanguage = .auto
    var targetLang: TranslationLanguage = .chinese
    var translationHistory: [HistoryEntry] = []

    @MainActor func syncFrom(_ state: AppState) {
        providers = state.providers
        selectedProviderID = state.selectedProviderID
        dictProviderID = state.dictProviderID
        sourceLang = state.sourceLang
        targetLang = state.targetLang
        translationHistory = state.translationHistory
    }
}

// MARK: - Translation Store

/// Orchestrates translation execution through the pipeline.
@Observable
final class TranslationStore {
    var translatedText: String = ""
    var dictionaryEntry: DictionaryEntry? = nil
    var translationHistory: [HistoryEntry] = []

    @ObservationIgnored
    private let pipeline = TranslationPipeline()

    @MainActor func syncFrom(_ state: AppState) {
        translatedText = state.translatedText
        dictionaryEntry = state.dictionaryEntry
        translationHistory = state.translationHistory
    }
}
