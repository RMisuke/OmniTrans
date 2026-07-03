import Foundation
import Carbon

let kAppVersion = "0.4-dev"

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Set by `FloatingPanel` during window drag to signal `ThrottledStream`
    /// to relax its flush interval (80→120ms), avoiding main-thread contention
    /// between streaming renders and AppKit event tracking.
    @MainActor static var isUserDraggingWindow = false

    @Published var providers: [APIProvider] = []
    @Published var selectedProviderID: UUID?
    /// Provider for word/dictionary lookups. Falls back to selectedProviderID if nil.
    @Published var dictProviderID: UUID?
    @Published var sourceLang: TranslationLanguage = .auto { didSet { ProviderStorageManager.saveSourceLang(sourceLang) } }
    @Published var targetLang: TranslationLanguage = .chinese { didSet { ProviderStorageManager.saveTargetLang(targetLang) } }
    // ── Streaming fields — computed property proxy → session SSOT ──
    // 20+ service consumers read/write AppState.shared.xxx unchanged,
    // but all mutations flow directly into the @Observable session store.
    var inputText: String {
        get { session.inputText }
        set { session.inputText = newValue }
    }
    var translatedText: String {
        get { session.translatedText }
        set { session.translatedText = newValue }
    }
    var isTranslating: Bool {
        get { session.isTranslating }
        set { session.isTranslating = newValue }
    }
    var errorMessage: String? {
        get { session.errorMessage }
        set { session.errorMessage = newValue }
    }
    var showPermissionHint: Bool {
        get { session.showPermissionHint }
        set { session.showPermissionHint = newValue }
    }
    @Published var translationHistory: [HistoryEntry] = []
    var streamingFinished: Bool {
        get { session.streamingFinished }
        set { session.streamingFinished = newValue }
    }
    var showSuccessPulse: Bool {
        get { session.showSuccessPulse }
        set { session.showSuccessPulse = newValue }
    }
    var showErrorShake: Bool {
        get { session.showErrorShake }
        set { session.showErrorShake = newValue }
    }
    var showErrorPulse: Bool {
        get { session.showErrorPulse }
        set { session.showErrorPulse = newValue }
    }
    var dictionaryEntry: DictionaryEntry? {
        get { session.dictionaryEntry }
        set { session.dictionaryEntry = newValue }
    }
    var isDictionaryMode: Bool {
        get { session.isDictionaryMode }
        set { session.isDictionaryMode = newValue }
    }
    var detectedIsWord: Bool {
        get { session.detectedIsWord }
        set { session.detectedIsWord = newValue }
    }

    /// Single source of truth for all streaming state.
    /// Views observe this via `@Environment(TranslationSessionStore.self)` for field-level
    /// SwiftUI observation — only StreamingTextView recomputes on text changes.
    let session = TranslationSessionStore()

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
        if UserDefaults.standard.object(forKey: "animations_enabled") == nil {
            UserDefaults.standard.set(true, forKey: "animations_enabled")
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
        // Reorder: non-native first, macOSNative last (ultimate fallback)
        var enabled = enabledProviders
        guard enabled.count > 1 else { return nil }
        var nativeItems: [APIProvider] = []
        enabled.removeAll(where: { if $0.kind == .macOSNative { nativeItems.append($0); return true }; return false })
        enabled.append(contentsOf: nativeItems)
        guard let idx = enabled.firstIndex(where: { $0.id == current.id }) else { return enabled.first }
        let next = (idx + 1) % enabled.count
        if next == idx { return nil }
        return enabled[next]
    }

    /// Returns full ordered fallback chain starting from `provider`.
    func fallbackChain(from provider: APIProvider) -> [APIProvider] {
        var enabled = enabledProviders
        guard !enabled.isEmpty else { return [provider] }
        // Reorder: non-native first, macOSNative last
        var nativeItems: [APIProvider] = []
        enabled.removeAll(where: { if $0.kind == .macOSNative { nativeItems.append($0); return true }; return false })
        enabled.append(contentsOf: nativeItems)
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
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false; showErrorPulse = false
        lastText = text; lastTarget = targetLang; lastProviderID = selectedProviderID

        activeStreamTask = Task { [weak self] in
            guard let self else { return }
            let (resolvedProvider, usingFallback) = await FallbackRouter.resolveWithFallback(provider)
            if usingFallback { print("[OmniTrans] Falling back to local Ollama") }

            let isWord = WordDetector.isWord(text)

            let effectiveProvider: APIProvider
            if isWord, let dictID = self.dictProviderID,
               let dictProvider = self.enabledProviders.first(where: { $0.id == dictID }) {
                effectiveProvider = dictProvider
            } else {
                effectiveProvider = resolvedProvider
            }

            let isDict = isWord && !effectiveProvider.kind.isTraditionalMT

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

                if isDict {
                    if effectiveProvider.kind == .macOSNative {
                        let entry = await MacOSNativeProvider.lookupWord(text)
                        self.dictionaryEntry = entry
                    } else if let entry = DictionaryEntry.parse(from: fullText, word: text) {
                        self.dictionaryEntry = entry
                    } else {
                        self.dictionaryEntry = nil
                    }
                } else {
                    self.dictionaryEntry = nil
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    self.showSuccessPulse = false
                }
                self.retryCount = 0
                self.addHistory(text: text, result: fullText, provider: effectiveProvider)
            } catch {
                if isDict && effectiveProvider.kind != .macOSNative {
                    print("[DictFallback] ⚡️ Dictionary mode timed out, switching to macOS native dictionary")
                    let entry = await MacOSNativeProvider.lookupWord(text)
                    self.dictionaryEntry = entry
                    await MainActor.run {
                        self.translatedText = ""
                        self.isTranslating = false
                        self.streamingFinished = true
                        self.showSuccessPulse = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                            self.showSuccessPulse = false
                        }
                    }
                    return
                }

                let fallbackOn = UserDefaults.standard.bool(forKey: "fallback_on_failure")
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

                if effectiveProvider.kind != .macOSNative {
                    do {
                        let r = try await TranslationService.translate(
                            text: text, sourceLang: self.sourceLang,
                            targetLang: self.targetLang, using: effectiveProvider
                        )
                        await MainActor.run {
                            self.translatedText = r.text
                            self.isTranslating = false; self.streamingFinished = true
                            self.showSuccessPulse = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                                self.showSuccessPulse = false
                            }
                        }
                        self.retryCount = 0
                        await MainActor.run { self.addHistory(text: text, result: r.text, provider: effectiveProvider) }
                    } catch {
                        let msg = error.localizedDescription
                        await MainActor.run {
                            self.errorMessage = msg
                            self.isTranslating = false
                            self.showErrorShake = true
                            self.showErrorPulse = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                                self.showErrorPulse = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                self.showErrorShake = false
                            }
                        }
                    }
                }
            }
        }
    }

    func resetForNew(text: String) {
        activeStreamTask?.cancel()
        inputText = text; translatedText = ""; errorMessage = nil; isTranslating = false; lastText = ""
        dictionaryEntry = nil; isDictionaryMode = false
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false; showErrorPulse = false
        showPermissionHint = !HotkeyManager.isTrusted && text.isEmpty
        retryCount = 0

        // Pre-allocate translatedText buffer: translations are typically 1×–3× source length.
        // This avoids ~log₂(N) heap reallocations during streaming token concatenation.
        session.translatedText.reserveCapacity(max(1024, text.count * 2))

        // Deferred memory purge after OCR / large-text operations:
        // OCR's Vision C++ buffers can keep 60MB+ resident; delay 2s then
        // tell kernel to reclaim free pages back to baseline (~60MB).
        if text.count > 500 || !isDictionaryMode {
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
                MemoryPurgeHelper.shared.purgeBackendCache()
            }
        }
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
        Task { await HistoryActor.shared.add(entry) }
        translationHistory.insert(entry, at: 0)
        let maxCount = UserDefaults.standard.integer(forKey: "max_history_count")
        let limit = maxCount > 0 ? maxCount : 100
        if translationHistory.count > limit { translationHistory = Array(translationHistory.prefix(limit)) }
    }

    func clearHistory() {
        translationHistory.removeAll()
        Task { await HistoryActor.shared.clear() }
    }

    /// Load full history on demand (called when user opens History tab)
    func loadFullHistory() {
        Task { await HistoryActor.shared.loadFromDisk() }
        translationHistory = ProviderStorageManager.loadHistory()
    }

    /// Trim history back to recent entries when leaving history tab
    func trimHistory() {
        if translationHistory.count > 20 {
            translationHistory = Array(translationHistory.prefix(20))
        }
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
