import Foundation
import Carbon

let kAppVersion = "0.4-dev"

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var providers: [APIProvider] = []
    @Published var selectedProviderID: UUID?
    /// Provider for word/dictionary lookups. Falls back to selectedProviderID if nil.
    @Published var dictProviderID: UUID?
    @Published var sourceLang: TranslationLanguage = .auto { didSet { ProviderStorageManager.saveSourceLang(sourceLang) } }
    @Published var targetLang: TranslationLanguage = .chinese { didSet { ProviderStorageManager.saveTargetLang(targetLang) } }
    @Published var inputText: String = ""
    @Published var translatedText: String = ""
    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?
    @Published var showPermissionHint: Bool = false
    @Published var translationHistory: [HistoryEntry] = []
    @Published var streamingFinished: Bool = false
    @Published var showSuccessPulse: Bool = false
    @Published var showErrorShake: Bool = false
    @Published var dictionaryEntry: DictionaryEntry? = nil
    @Published var isDictionaryMode: Bool = false
    /// Auto-detected word status — updated on inputText change, drives UI hints.
    @Published var detectedIsWord: Bool = false

    var selectedProvider: APIProvider? { providers.first { $0.id == selectedProviderID && $0.isEnabled } }
    var enabledProviders: [APIProvider] { providers.filter(\.isEnabled) }

    private var lastText = ""
    private var lastTarget: TranslationLanguage = .chinese
    private var lastProviderID: UUID? = nil
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
        KeychainManager.debugDump()  // debug: verify keys on launch
        providers = ProviderStorageManager.loadProviders()
        // Native always first
        providers.sort { $0.kind == .macOSNative && $1.kind != .macOSNative }
        // Ensure built-in macOS native provider always exists
        if !providers.contains(where: { $0.kind == .macOSNative }) {
            providers.insert(.native, at: 0)
        }
        // Refresh the native entry to latest definition in case it changed
        if let idx = providers.firstIndex(where: { $0.kind == .macOSNative }) {
            providers[idx].name = APIProvider.native.name
            providers[idx].modelName = APIProvider.native.modelName
            providers[idx].isEnabled = APIProvider.native.isEnabled
        }
        selectedProviderID = ProviderStorageManager.loadSelectedProviderID() ?? enabledProviders.first?.id
        dictProviderID = ProviderStorageManager.loadDictProviderID()
        // Default dict provider to macOS built-in if never configured
        if dictProviderID == nil, let native = providers.first(where: { $0.kind == .macOSNative }) {
            dictProviderID = native.id
        }
        sourceLang = ProviderStorageManager.loadSourceLang()
        targetLang = ProviderStorageManager.loadTargetLang()
        translationHistory = ProviderStorageManager.loadHistory()
    }

    func save() {
        providers.sort { $0.kind == .macOSNative && $1.kind != .macOSNative }; ProviderStorageManager.saveProviders(providers)
    }

    func deleteProvider(_ p: APIProvider) {
        guard !p.isBuiltIn else { return }
        providers.removeAll { $0.id == p.id }
        ProviderStorageManager.deleteProviderKey(id: p.id)
        if selectedProviderID == p.id { selectedProviderID = enabledProviders.first?.id }
        ProviderStorageManager.saveSelectedProviderID(selectedProviderID)
        save()
    }

    func ensureKey(for provider: APIProvider) -> APIProvider {
        var p = provider
        if p.apiKey.isEmpty, let key = ProviderStorageManager.loadProviderKey(for: p.id), !key.isEmpty {
            p.apiKey = key
            if let i = providers.firstIndex(where: { $0.id == p.id }) {
                providers[i].apiKey = key
            }
        }
        return p
    }

    func updateProvider(_ updated: APIProvider) {
        guard !updated.isBuiltIn else { return }
        if let i = providers.firstIndex(where: { $0.id == updated.id }) {
            providers[i] = updated; save()
        }
        if updated.isEnabled, selectedProviderID == nil { selectedProviderID = updated.id }
    }

    func addProvider(_ p: APIProvider) {
        providers.append(p); save()
    }

    // MARK: - Translation

    /// Returns the next enabled provider after `current` in list order (wraps around).
    /// Returns nil if no other enabled provider exists.
    func nextFallbackProvider(after current: APIProvider) -> APIProvider? {
        let enabled = enabledProviders
        guard enabled.count > 1 else { return nil }
        guard let idx = enabled.firstIndex(where: { $0.id == current.id }) else {
            return enabled.first
        }
        let next = (idx + 1) % enabled.count
        if next == idx { return nil }
        return enabled[next]
    }

    /// Returns full ordered fallback chain starting from `provider`.
    func fallbackChain(from provider: APIProvider) -> [APIProvider] {
        let enabled = enabledProviders
        guard !enabled.isEmpty else { return [provider] }
        guard let idx = enabled.firstIndex(where: { $0.id == provider.id }) else { return enabled }
        var chain: [APIProvider] = []
        for i in idx..<enabled.count { chain.append(enabled[i]) }
        for i in 0..<idx { chain.append(enabled[i]) }
        return chain
    }


    func retryTranslate() {
        translate()
    }

    func translate() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let p = selectedProvider, p.isEnabled else { errorMessage = "请先选择并配置一个可用的 API"; return }
        // Skip if nothing changed (same text, target, and provider)
        if text == lastText, targetLang == lastTarget, selectedProviderID == lastProviderID, !translatedText.isEmpty { return }

        retryCount = 0
        doTranslate(text: text, provider: p)
    }

    private func doTranslate(text: String, provider: APIProvider) {
        activeStreamTask?.cancel()
        isTranslating = true; errorMessage = nil; translatedText = ""
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false
        lastText = text; lastTarget = targetLang; lastProviderID = selectedProviderID

        activeStreamTask = Task { [weak self] in
            guard let self else { return }
            let (resolvedProvider, usingFallback) = await TranslationActor.shared.resolveWithFallback(provider)
            if usingFallback { print("[OmniTrans] Falling back to local Ollama") }

            let isWord = WordDetector.isWord(text)

            // Pick the right provider: dict config first, then fallback to current selection
            let effectiveProvider: APIProvider
            if isWord, let dictID = self.dictProviderID,
               let dictProvider = self.enabledProviders.first(where: { $0.id == dictID }) {
                effectiveProvider = dictProvider
            } else {
                effectiveProvider = resolvedProvider
            }

            // Dict mode only if it's a word AND the effective provider supports it
            let isDict = isWord && !effectiveProvider.kind.isTraditionalMT

            // ── Route via factory (fallback handled at AppState level) ──
            let ctx = EngineRoutingContext(text: text, provider: effectiveProvider, isWord: isDict)
            let engine = TranslationEngineFactory.makeEngine(context: ctx)
            let stream = engine.execute(
                text: text,
                provider: effectiveProvider,
                isDictionaryMode: isDict,
                sourceLang: self.sourceLang,
                targetLang: self.targetLang
            )

            if isDict { self.isDictionaryMode = true }

            var fullText = ""
            var lastFlush = ContinuousClock.Instant.now
            let flushInterval = Duration.milliseconds(50)

            do {
                for try await token in stream {
                    fullText += token
                    let now = ContinuousClock.Instant.now
                    if !isDict, (now - lastFlush) >= flushInterval {
                        self.translatedText = fullText
                        lastFlush = now
                    }
                }
                if !isDict {
                    self.translatedText = fullText
                }
                self.isTranslating = false
                self.streamingFinished = true
                self.showSuccessPulse = true
                self.isDictionaryMode = false

                // Parse dictionary result
                if isDict {
                    if effectiveProvider.kind == .macOSNative {
                        self.dictionaryEntry = MacOSNativeProvider.lookupWord(text)
                    } else if let entry = DictionaryEntry.parse(from: fullText, word: text) {
                        self.dictionaryEntry = entry
                    } else {
                        self.dictionaryEntry = nil
                    }
                } else {
                    self.dictionaryEntry = nil
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.showSuccessPulse = false
                }
                self.retryCount = 0
                self.addHistory(text: text, result: fullText, provider: effectiveProvider)
            } catch {
                // ── Sequential fallback: try next enabled provider ──
                let fallbackOn = UserDefaults.standard.bool(forKey: "fallback_on_failure")
                // Be lenient: treat any error as fallback-eligible, except auth errors
                let errStr = error.localizedDescription.lowercased()
                let isAuthError = errStr.contains("401") || errStr.contains("403") || errStr.contains("unauthorized") || errStr.contains("invalid api key") || errStr.contains("key 无效")

                print("[Fallback] fallbackOn=\(fallbackOn) isAuth=\(isAuthError) error=\(error.localizedDescription.prefix(80))")

                if fallbackOn, !isAuthError, let next = self.nextFallbackProvider(after: effectiveProvider) {
                    print("[Fallback] Switching \(effectiveProvider.name) → \(next.name)")
                    await MainActor.run {
                        self.selectedProviderID = next.id
                        ProviderStorageManager.saveSelectedProviderID(next.id)
                    }
                    self.doTranslate(text: text, provider: next)
                    return
                }

                // ── Fallback to non-streaming for same provider ──
                do {
                    let r = try await TranslationService.translate(
                        text: text, sourceLang: self.sourceLang,
                        targetLang: self.targetLang, using: effectiveProvider
                    )
                    await MainActor.run {
                        self.translatedText = r.text
                        self.isTranslating = false; self.streamingFinished = true
                        self.showSuccessPulse = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            self.showSuccessPulse = false
                        }
                    }
                    self.retryCount = 0
                    await MainActor.run { self.addHistory(text: text, result: r.text, provider: effectiveProvider) }
                } catch {
                    // ── Terminal error ──
                    let msg = effectiveProvider.kind == .macOSNative
                        ? Self.friendlyNativeError(error)
                        : error.localizedDescription
                    await MainActor.run {
                        self.errorMessage = msg
                        self.isTranslating = false
                        self.showErrorShake = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.showErrorShake = false
                        }
                    }
                }
            }
        }
    }

    func resetForNew(text: String) {
        activeStreamTask?.cancel()
        inputText = text; translatedText = ""; errorMessage = nil; isTranslating = false; lastText = ""; dictionaryEntry = nil; isDictionaryMode = false
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false
        retryCount = 0
        showPermissionHint = !HotkeyManager.isTrusted && text.isEmpty
    }

        /// Maps Translation framework errors (and other native errors) to user-friendly Chinese messages.
    private static func friendlyNativeError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("not installed") || desc.contains("notinstalled") {
            return "本地语言包未安装。请前往 系统设置 → 隐私与安全性 → 翻译语言 下载所需语言包。"
        }
        if desc.contains("unsupported") && desc.contains("language") {
            return "该语言对暂时不被系统原生翻译支持。请切换至云端 API。"
        }
        if desc.contains("unable") && desc.contains("identify") {
            return "系统无法识别源文本语言，请手动指定源语言后重试。"
        }
        if desc.contains("nothing") && desc.contains("translate") {
            return "未检测到可翻译的文本内容。"
        }
        if desc.contains("internal") {
            return "系统翻译引擎内部错误，请稍后重试或切换至云端 API。"
        }
        return "原生翻译失败: \(error.localizedDescription)"
    }

    func addHistory(text: String, result: String, provider: APIProvider) {
        guard !UserDefaults.standard.bool(forKey: "history_disabled") else { return }
        let entry = HistoryEntry(input: text, output: result, sourceLang: sourceLang, targetLang: targetLang, providerName: provider.name, model: provider.modelName)
        translationHistory.insert(entry, at: 0)
        let maxCount = UserDefaults.standard.integer(forKey: "max_history_count")
        let limit = maxCount > 0 ? maxCount : 100
        if translationHistory.count > limit { translationHistory = Array(translationHistory.prefix(limit)) }
        ProviderStorageManager.saveHistory(translationHistory)
    }

    func clearHistory() {
        translationHistory.removeAll()
        ProviderStorageManager.clearHistory()
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
