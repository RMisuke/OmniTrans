import Foundation
import Carbon

let kAppVersion = "0.2"

/// BISECT DEBUG: Reverted to v0.1 monolithic structure to isolate crash.
/// Stores and TranslationActor exist but unused by AppState in this build.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private static let providersKey = "saved_providers_v2"
    private static let sourceLangKey = "source_lang"
    private static let targetLangKey = "target_lang"
    private static let historyKey = "translation_history"

    @Published var providers: [APIProvider] = []
    @Published var selectedProviderID: UUID?
    @Published var sourceLang: TranslationLanguage = .auto { didSet { saveLanguages() } }
    @Published var targetLang: TranslationLanguage = .chinese { didSet { saveLanguages() } }
    @Published var inputText: String = ""
    @Published var translatedText: String = ""
    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?
    @Published var showPermissionHint: Bool = false
    @Published var translationHistory: [HistoryEntry] = []
    @Published var streamingFinished: Bool = false
    @Published var showSuccessPulse: Bool = false
    @Published var showErrorShake: Bool = false

    var selectedProvider: APIProvider? { providers.first { $0.id == selectedProviderID && $0.isEnabled } }
    var enabledProviders: [APIProvider] { providers.filter(\.isEnabled) }

    private var lastText = ""
    private var lastTarget: TranslationLanguage = .chinese
    private var retryCount = 0
    private let maxAutoRetry = 1
    private var activeStreamTask: Task<Void, Never>?

    init() {
        load()
        if UserDefaults.standard.integer(forKey: "hotkey_carbonKey") == 0 {
            UserDefaults.standard.set(Int(kVK_ANSI_D), forKey: "hotkey_carbonKey")
            UserDefaults.standard.set(Int(optionKey), forKey: "hotkey_carbonMods")
        }
        if UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonKey") == 0 {
            UserDefaults.standard.set(Int(kVK_ANSI_F), forKey: "ocr_hotkey_carbonKey")
            UserDefaults.standard.set(Int(optionKey), forKey: "ocr_hotkey_carbonMods")
        }
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.providersKey),
              let d = try? JSONDecoder().decode([APIProvider].self, from: data) else { return }
        providers = d
        selectedProviderID = enabledProviders.first?.id

        if let raw = UserDefaults.standard.string(forKey: Self.sourceLangKey),
           let lang = TranslationLanguage(rawValue: raw) {
            sourceLang = lang
        }
        if let raw = UserDefaults.standard.string(forKey: Self.targetLangKey),
           let lang = TranslationLanguage(rawValue: raw), lang != .auto {
            targetLang = lang
        }

        if let d = UserDefaults.standard.data(forKey: Self.historyKey),
           let h = try? JSONDecoder().decode([HistoryEntry].self, from: d) {
            translationHistory = h
        }
    }

    func save() {
        for p in providers where !p.apiKey.isEmpty { KeychainManager.save(key: p.id.uuidString, value: p.apiKey) }
        var s = providers; for i in s.indices { s[i].apiKey = "" }
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.providersKey) }
    }

    func saveLanguages() {
        UserDefaults.standard.set(sourceLang.rawValue, forKey: Self.sourceLangKey)
        UserDefaults.standard.set(targetLang.rawValue, forKey: Self.targetLangKey)
    }

    func deleteProvider(_ p: APIProvider) {
        providers.removeAll { $0.id == p.id }
        KeychainManager.delete(key: p.id.uuidString)
        if selectedProviderID == p.id { selectedProviderID = enabledProviders.first?.id }
        save()
    }

    func ensureKey(for provider: APIProvider) -> APIProvider {
        var p = provider
        if p.apiKey.isEmpty, let key = KeychainManager.get(key: p.id.uuidString), !key.isEmpty {
            p.apiKey = key
            if let i = providers.firstIndex(where: { $0.id == p.id }) {
                providers[i].apiKey = key
            }
        }
        return p
    }

    func updateProvider(_ updated: APIProvider) {
        if let i = providers.firstIndex(where: { $0.id == updated.id }) {
            providers[i] = updated; save()
        }
        if updated.isEnabled, selectedProviderID == nil { selectedProviderID = updated.id }
    }

    func addProvider(_ p: APIProvider) {
        providers.append(p); save()
    }

    // MARK: - Translation (uses existing TranslationService, NOT actor)

    func translate() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text == lastText, targetLang == lastTarget, !translatedText.isEmpty { return }
        guard let p = selectedProvider, p.isEnabled else { errorMessage = "请先选择并配置一个可用的 API"; return }

        retryCount = 0
        doTranslate(text: text, provider: ensureKey(for: p))
    }

    func retryTranslate() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let p = selectedProvider, p.isEnabled else { return }
        doTranslate(text: text, provider: ensureKey(for: p))
    }

    private func doTranslate(text: String, provider: APIProvider) {
        activeStreamTask?.cancel()
        isTranslating = true; errorMessage = nil; translatedText = ""
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false
        lastText = text; lastTarget = targetLang

        activeStreamTask = Task { [weak self] in
            guard let self else { return }
            // v0.2: Try Ollama fallback if main provider is unreachable
            let (resolvedProvider, usingFallback) = await TranslationActor.shared.resolveWithFallback(provider)
            if usingFallback {
                print("[OmniTrans] Falling back to local Ollama")
            }
            let stream = await TranslationActor.shared.translateStream(
                text: text, sourceLang: self.sourceLang,
                targetLang: self.targetLang, provider: resolvedProvider
            )
            var fullText = ""
            var lastFlush = ContinuousClock.Instant.now
            let flushInterval = Duration.milliseconds(50)

            do {
                for try await token in stream {
                    fullText += token
                    let now = ContinuousClock.Instant.now
                    if (now - lastFlush) >= flushInterval {
                        self.translatedText = fullText
                        lastFlush = now
                    }
                }
                self.translatedText = fullText
                self.isTranslating = false
                self.streamingFinished = true
                self.showSuccessPulse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.showSuccessPulse = false }
                self.retryCount = 0
                self.addHistory(text: text, result: fullText, provider: resolvedProvider)
            } catch {
                do {
                    let r = try await TranslationService.translate(text: text, sourceLang: self.sourceLang, targetLang: self.targetLang, using: provider)
                    self.translatedText = r.text
                    self.isTranslating = false; self.streamingFinished = true
                    self.showSuccessPulse = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.showSuccessPulse = false }
                    self.retryCount = 0
                    self.addHistory(text: text, result: r.text, provider: provider)
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.isTranslating = false
                    self.showErrorShake = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showErrorShake = false }
                    let errMsg = error.localizedDescription.lowercased()
                    let isNetworkError = errMsg.contains("网络") || errMsg.contains("network")
                        || errMsg.contains("timeout") || errMsg.contains("connection")
                    if self.retryCount < self.maxAutoRetry, isNetworkError {
                        self.retryCount += 1
                        self.doTranslate(text: text, provider: provider)
                    }
                }
            }
        }
    }

    func resetForNew(text: String) {
        activeStreamTask?.cancel()
        inputText = text; translatedText = ""; errorMessage = nil; isTranslating = false; lastText = ""
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false
        retryCount = 0
        showPermissionHint = !HotkeyManager.isTrusted && text.isEmpty
    }

    func addHistory(text: String, result: String, provider: APIProvider) {
        let entry = HistoryEntry(input: text, output: result, sourceLang: sourceLang, targetLang: targetLang, providerName: provider.name, model: provider.modelName)
        translationHistory.insert(entry, at: 0)
        let maxCount = UserDefaults.standard.integer(forKey: "max_history_count")
        let limit = maxCount > 0 ? maxCount : 100
        if translationHistory.count > limit { translationHistory = Array(translationHistory.prefix(limit)) }
        if let d = try? JSONEncoder().encode(translationHistory) { UserDefaults.standard.set(d, forKey: Self.historyKey) }
    }

    func clearHistory() {
        translationHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let input: String; let output: String
    let sourceLang: TranslationLanguage; let targetLang: TranslationLanguage
    let providerName: String; let model: String
    let timestamp: Date

    init(input: String, output: String, sourceLang: TranslationLanguage, targetLang: TranslationLanguage, providerName: String, model: String) {
        self.id = UUID(); self.input = input; self.output = output
        self.sourceLang = sourceLang; self.targetLang = targetLang
        self.providerName = providerName; self.model = model
        self.timestamp = Date()
    }
}
