import Foundation
import Carbon

let kAppVersion = "0.6"

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Set by `FloatingPanel` during window drag to signal `ThrottledStream`
    /// to relax its flush interval (80→120ms), avoiding main-thread contention
    /// between streaming renders and AppKit event tracking.
    @MainActor static var isUserDraggingWindow = false

    @Published var providers: [APIProvider] = []
    @Published var selectedProviderID: UUID? { didSet { FallbackRouter.invalidatePrimaryProbe() } }
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

    /// Low-frequency configuration state (providers, languages, context toggle, etc.).
    /// Views can observe `AppState.shared.configuration` for reactive settings updates.
    let configuration = ConfigurationStore()

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
        // ── Core defaults: @AppStorage keys used across panels ──
        // register(defaults:) never overwrites an existing value, so it's
        // safe to call on every launch regardless of first-vs-subsequent runs.
        UserDefaults.standard.register(defaults: [
            "panel_size": "default",
            "dismiss_mode": "clickOutside",
            "clipboard_monitor": false,
            "history_disabled": false,
            "max_history_count": 100,
            "cache_enabled": true,
            "is_context_aware": true,
            "context_intensity": 2,
            "custom_prompt_enabled": false,
            "custom_prompt_text": "",
            "dict_cache_enabled": true,
            "translation_temperature": 0.3,
            "translation_maxTokens": 1024,
            "animations_enabled": true,
        ])

        // ── Hotkey first-launch defaults ──
        if UserDefaults.standard.integer(forKey: "hotkey_carbonKey") == 0 {
            UserDefaults.standard.set(Int(kVK_ANSI_D), forKey: "hotkey_carbonKey")
            UserDefaults.standard.set(Int(optionKey), forKey: "hotkey_carbonMods")
        }
        if UserDefaults.standard.integer(forKey: "ocr_hotkey_carbonKey") == 0 {
            UserDefaults.standard.set(Int(kVK_ANSI_F), forKey: "ocr_hotkey_carbonKey")
            UserDefaults.standard.set(Int(optionKey), forKey: "ocr_hotkey_carbonMods")
        }
        if UserDefaults.standard.integer(forKey: "replace_hotkey_carbonKey") == 0 {
            UserDefaults.standard.set(Int(kVK_ANSI_R), forKey: "replace_hotkey_carbonKey")
            UserDefaults.standard.set(Int(optionKey), forKey: "replace_hotkey_carbonMods")
        }

        // Cache limits are configured inside TranslationCache / DictEntryCache init.
    }

    func load() {
        #if DEBUG
        KeychainManager.debugDump()  // debug: verify keys on launch
        #endif
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
        // ── Phase 1: fast first-frame from UserDefaults (≤50 entries) ──
        translationHistory = ProviderStorageManager.loadHistory()

        // ── Phase 2: async reload from JSONL archive → UserDefaults sync → update UI ──
        // The actor's loadFromDisk() reads the full JSONL history (up to
        // maxHistoryCount), saves the capped set back to UserDefaults, and
        // then we re-read UserDefaults into translationHistory so the UI
        // shows all available entries — not just the ≤50 first-frame set.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await HistoryActor.shared.loadFromDisk()
            let full = ProviderStorageManager.loadHistory()
            let deduped = Self.deduplicateAdjacentEntries(full)
            self.translationHistory = Array(deduped.prefix(self.maxHistoryCount))
        }
    }

    func save() {
        providers.sort { $0.kind == .macOSNative && $1.kind != .macOSNative }; ProviderStorageManager.saveProviders(providers)
    }

    func deleteProvider(_ p: APIProvider) {
        guard !p.isBuiltIn else { return }
        providers.removeAll { $0.id == p.id }
        ProviderStorageManager.deleteProviderSecrets(for: p.id)
        if selectedProviderID == p.id { selectedProviderID = enabledProviders.first?.id }
        ProviderStorageManager.saveSelectedProviderID(selectedProviderID)
        save()
    }

    func ensureKey(for provider: APIProvider) -> APIProvider {
        var p = provider
        if p.apiKey.isEmpty {
            let key = ProviderStorageManager.cachedValue(for: p.id, field: "apiKey")
            if !key.isEmpty {
                p.apiKey = key
                if let i = providers.firstIndex(where: { $0.id == p.id }) {
                    providers[i].apiKey = key
                }
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
        Self.nextFallbackProvider(after: current, in: enabledProviders)
    }

    /// Returns full ordered fallback chain starting from `provider`.
    func fallbackChain(from provider: APIProvider) -> [APIProvider] {
        Self.fallbackChain(from: provider, in: enabledProviders)
    }


    func retryTranslate() {
        translate(forceRefresh: true)
    }

    /// In-memory translation cache — avoids redundant API calls.
    private let translationCache = TranslationCache()
    /// In-memory dictionary lookup cache — avoids redundant LLM/macOS dict calls.
    private let dictEntryCache = DictEntryCache()

    func translate(context: CapturedContext? = nil, forceRefresh: Bool = false) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let p = selectedProvider, p.isEnabled else { errorMessage = "请先选择并配置一个可用的 API"; return }

        // Reset local cache flags
        session.isFromLocalCache = false
        session.cachedModelName = ""
        session.cacheTimestamp = ""

        // ── Cache gate ──
        let cacheOn = configuration.isCacheEnabled

        // ── Composite cache key: text + lang + provider + context-awareness state ──
        let cacheKey = Self.buildCacheKey(text: text, targetLang: targetLang, providerID: p.id, isContextAwareEnabled: configuration.isContextAwareEnabled, contextIntensity: configuration.contextIntensity, context: context) as NSString
        if cacheOn, let cached = translationCache.get(cacheKey) {
            translatedText = cached
            isTranslating = false; streamingFinished = true
            showSuccessPulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                self?.showSuccessPulse = false
            }
            return
        }

        // Skip if nothing changed (same text, target, and provider)
        if text == lastText, targetLang == lastTarget, selectedProviderID == lastProviderID, !translatedText.isEmpty { return }

        retryCount = 0
        doTranslate(text: text, provider: p, context: context, forceRefresh: forceRefresh)
    }

    @MainActor
    private func doTranslate(text: String, provider: APIProvider, context: CapturedContext? = nil, forceRefresh: Bool = false) {
        activeStreamTask?.cancel()
        isTranslating = true; errorMessage = nil; translatedText = ""
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false; showErrorPulse = false
        lastText = text; lastTarget = targetLang; lastProviderID = selectedProviderID

        activeStreamTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            // Probe is deferred to FallbackRouter.resolveWithFallback() only on
            // failure — uses lightweight HEAD request (M2), consuming no API quota.
            // Success path skips probe entirely for minimum latency.
            let isWord = WordDetector.isWord(text)

            let effectiveProvider: APIProvider
            if isWord, let dictID = self.dictProviderID,
               let dictProvider = self.enabledProviders.first(where: { $0.id == dictID }) {
                effectiveProvider = dictProvider
            } else {
                effectiveProvider = provider
            }

            let isDict = isWord && !effectiveProvider.kind.isTraditionalMT

            // ═══════════════════════════════════════════════════════════════
            // 个人词典缓存 (Dictionary Cache)
            // 设计原则:
            //   1. 缓存键 = (单词小写, 目标语言) — 不依赖 provider ID
            //   2. 写入一次, 永久有效 — 只有 forceRefresh 才覆盖
            //   3. 无过期策略 — 用户专属的个人词典数据库
            // ═══════════════════════════════════════════════════════════════
            let cacheEnabled = self.configuration.isDictCacheEnabled
            let langKey = self.targetLang.rawValue

            // ── L1 内存缓存 (最快, 零 I/O) ──
            if isDict, !forceRefresh, cacheEnabled {
                let l1Key = "\(text.lowercased())_\(langKey)" as NSString
                if let cachedEntry = dictEntryCache.get(l1Key) {
                    self.dictionaryEntry = cachedEntry
                    self.isDictionaryMode = true
                    self.isTranslating = false
                    self.session.isFromLocalCache = true
                    self.session.cachedModelName = ""
                    self.session.cacheTimestamp = ""
                    self.streamingFinished = true
                    self.showSuccessPulse = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.showSuccessPulse = false }
                    self.addHistory(text: text, result: "", provider: effectiveProvider)
                    self.isDictionaryMode = false
                    return
                }
            }

            // ── L2 SQLite 持久缓存 (磁盘 I/O, 命中后预热 L1) ──
            if isDict, !forceRefresh, cacheEnabled {
                if let cached = await LocalDictionaryRepository.shared.fetchEntry(word: text, targetLang: langKey),
                   let entry = DictionaryEntry.parse(from: cached.jsonData, word: text) {
                    // Warm L1 — 后续查询零 I/O 直接命中内存
                    let l1Key = "\(text.lowercased())_\(langKey)" as NSString
                    self.dictEntryCache.set(entry, forKey: l1Key)
                    // Populate UI
                    self.dictionaryEntry = entry
                    self.isDictionaryMode = true
                    self.isTranslating = false
                    self.session.isFromLocalCache = true
                    self.session.cachedModelName = cached.modelName
                    self.session.cacheTimestamp = cached.timestamp
                    self.streamingFinished = true
                    self.showSuccessPulse = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.showSuccessPulse = false }
                    self.addHistory(text: text, result: cached.jsonData, provider: effectiveProvider)
                    self.isDictionaryMode = false
                    return
                }
            }

            let ctx = EngineRoutingContext(text: text, provider: effectiveProvider, isWord: isDict)
            let engine = TranslationEngineFactory.makeEngine(context: ctx)
            let stream = engine.execute(
                text: text,
                provider: effectiveProvider,
                isDictionaryMode: isDict,
                sourceLang: self.sourceLang,
                targetLang: self.targetLang,
                context: context
            )

            if isDict { self.isDictionaryMode = true }

            // ── O(1) amortized: collect chunks in array, join at flush ──
            let dictParser: StreamingDictParser? = isDict ? StreamingDictParser(word: text) : nil
            var chunks: [String] = []
            chunks.reserveCapacity(64)

            do {
                for try await batch in stream {
                    chunks.append(batch)
                    if isDict, let parser = dictParser {
                        if let partial = await parser.feed(batch) {
                            self.dictionaryEntry = partial
                        }
                    } else {
                        // @MainActor Task — direct update, no actor hop needed
                        self.translatedText = chunks.joined()
                    }
                }
                if !isDict {
                    self.translatedText = chunks.joined()
                }

                // ── Cache successful result (composite key, 仅用于非词典模式) ──
                if !isDict, self.configuration.isCacheEnabled {
                    let fullText = chunks.joined()
                    let ck = Self.buildCacheKey(text: text, targetLang: self.targetLang, providerID: effectiveProvider.id, isContextAwareEnabled: self.configuration.isContextAwareEnabled, contextIntensity: self.configuration.contextIntensity, context: context) as NSString
                    self.translationCache.set(fullText, forKey: ck)
                }

                if isDict {
                    if effectiveProvider.kind == .macOSNative {
                        let entry = await MacOSNativeProvider.lookupWord(text)
                        self.dictionaryEntry = entry
                        if entry.isWord {
                            // Native 结果仅存 L1 (本地查询无 token 消耗)
                            let dk = "\(text.lowercased())_\(langKey)" as NSString
                            self.dictEntryCache.set(entry, forKey: dk)
                        }
                    } else if let parser = dictParser,
                              let entry = await parser.flush() {
                        self.dictionaryEntry = entry
                        let fullText = chunks.joined()
                        // ── Hard-lock: 菜单栏兜底渲染 ──
                        self.session.lastValidDictionaryJson = fullText
                        // ── L1 内存缓存 (同一 session 内零 I/O) ──
                        let dk = "\(text.lowercased())_\(langKey)" as NSString
                        self.dictEntryCache.set(entry, forKey: dk)
                        // ── L2 SQLite 持久化 (write-once, 仅 forceRefresh 覆盖) ──
                        let model = effectiveProvider.modelName
                        Task.detached(priority: .utility) {
                            await LocalDictionaryRepository.shared.saveEntry(
                                word: text, targetLang: langKey,
                                modelName: model, jsonData: fullText,
                                overwrite: forceRefresh
                            )
                        }
                    } else {
                        self.dictionaryEntry = nil
                    }
                } else {
                    self.dictionaryEntry = nil
                }

                // ── End translation AFTER dictionaryEntry is set ──
                // Must come after dictionaryEntry assignment so SwiftUI
                // never observes isTranslating=false while dictionaryEntry
                // is still nil (would render blank Spacer in middleArea).
                self.isTranslating = false
                self.streamingFinished = true
                self.showSuccessPulse = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    self.showSuccessPulse = false
                }
                self.retryCount = 0
                // ⚠️ addHistory must be called BEFORE isDictionaryMode reset,
                // otherwise HistoryEntry.isDictionaryMode is always false
                self.addHistory(text: text, result: chunks.joined(), provider: effectiveProvider)
                self.isDictionaryMode = false
            } catch {
                NetworkLogger.logError("Stream", error)

                if isDict && effectiveProvider.kind != .macOSNative {
                    NetworkLogger.log("DictFallback", "switching to macOS native dictionary")
                    // Try flushing partial results before fallback
                    if let parser = dictParser, let partial = await parser.flush() {
                        self.dictionaryEntry = partial
                    }
                    let entry = await MacOSNativeProvider.lookupWord(text)
                    if entry.isWord { self.dictionaryEntry = entry }
                    self.translatedText = ""
                    self.isTranslating = false
                    self.streamingFinished = true
                    self.showSuccessPulse = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                        self.showSuccessPulse = false
                    }
                    return
                }

                let fallbackOn = UserDefaults.standard.bool(forKey: "fallback_on_failure")
                let errStr = error.localizedDescription.lowercased()
                let isAuthError = errStr.contains("401") || errStr.contains("403") || errStr.contains("unauthorized") || errStr.contains("invalid api key") || errStr.contains("key 无效")

                NetworkLogger.log("Fallback", "fallbackOn=\(fallbackOn) isAuth=\(isAuthError) error=\(error.localizedDescription.prefix(80))")

                if fallbackOn, !isAuthError, let next = Self.nextFallbackProvider(after: effectiveProvider, in: self.enabledProviders) {
                    NetworkLogger.log("Fallback", "switching \(effectiveProvider.name) → \(next.name)")
                    self.selectedProviderID = next.id
                    ProviderStorageManager.saveSelectedProviderID(next.id)
                    self.doTranslate(text: text, provider: next, context: context)
                    return
                }

                if effectiveProvider.kind != .macOSNative {
                    do {
                        // L7: Retry non-streaming fallback with exponential backoff
                        // (transient network errors, not auth errors which are caught above)
                        let r = try await RetryUtility.retryWithBackoff(
                            maxRetries: 2,
                            baseDelay: 0.5,
                            isRetryable: { error in
                                let s = error.localizedDescription.lowercased()
                                return !s.contains("401") && !s.contains("403")
                                    && !s.contains("unauthorized") && !s.contains("invalid api key")
                            }
                        ) {
                            try await TranslationService.translate(
                                text: text, sourceLang: self.sourceLang,
                                targetLang: self.targetLang, using: effectiveProvider
                            )
                        }
                        self.translatedText = r.text
                        self.isTranslating = false; self.streamingFinished = true
                        self.showSuccessPulse = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                            self.showSuccessPulse = false
                        }
                        self.retryCount = 0
                        self.addHistory(text: text, result: r.text, provider: effectiveProvider)
                    } catch {
                        NetworkLogger.logError("NonStreamingFallback", error)
                        let msg = error.localizedDescription
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
                Task { @MainActor in MemoryPurgeHelper.shared.purgeBackendCache() }
            }
        }
    }


    /// Maximum history entries as configured in Settings.  Reads from
    /// `UserDefaults.max_history_count`, defaulting to 100.
    var maxHistoryCount: Int {
        let count = UserDefaults.standard.integer(forKey: "max_history_count")
        return count > 0 ? count : 100
    }

    /// Immediately applies `maxHistoryCount` to both the in-memory history
    /// and the persistent JSONL archive.  Also runs a dedup pass to collapse
    /// adjacent entries with identical provider + output.
    func applyHistoryLimit() {
        let cap = maxHistoryCount
        let deduped = Self.deduplicateAdjacentEntries(translationHistory)
        translationHistory = Array(deduped.prefix(cap))
        Task { await HistoryActor.shared.applyLimitAndDedup(limit: cap) }
    }

    /// Restore UI state from a history entry **without** making an API call.
    ///
    /// For standard translations, populates `inputText` and `translatedText`
    /// directly from the cached entry.  For dictionary lookups, attempts to
    /// parse the stored JSON output into `dictionaryEntry`.
    ///
    /// Only falls back to `translate()` when the entry's `output` is empty
    /// (e.g. a previously failed translation), letting the cache gate in
    /// `translate()` serve the result if it's still warm.
    func recallHistoryEntry(_ entry: HistoryEntry) {
        inputText = entry.input
        isTranslating = false
        streamingFinished = true
        errorMessage = nil

        if entry.isDictionaryMode {
            // Try to reconstruct the dictionary entry from the stored JSON output
            if !entry.output.isEmpty,
               let data = entry.output.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(DictionaryEntry.self, from: data) {
                dictionaryEntry = parsed
                isDictionaryMode = true
            } else {
                // Stored output is unparseable — fall back to a fresh lookup
                isDictionaryMode = true
                translate()
                return
            }
        } else {
            // Standard translation: show cached result directly
            translatedText = entry.output
            isDictionaryMode = false
            dictionaryEntry = nil

            // If the entry has no output (failed translation), attempt a fresh call
            if entry.output.isEmpty {
                translate()
                return
            }
        }

        showSuccessPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.showSuccessPulse = false
        }
    }

    func addHistory(text: String, result: String, provider: APIProvider,
                    durationMs: Int? = nil,
                    tokenCount: Int? = nil,
                    errorMessage: String? = nil) {
        guard !UserDefaults.standard.bool(forKey: "history_disabled") else { return }
        let entry = HistoryEntry(
            input: text, output: result,
            sourceLang: sourceLang, targetLang: targetLang,
            providerName: provider.name, model: provider.modelName,
            isContextAwareEnabled: configuration.isContextAwareEnabled,
            isDictionaryMode: isDictionaryMode,
            durationMs: durationMs,
            tokenCount: tokenCount,
            errorMessage: errorMessage
        )

        // Dedup: if the most recent entry has the same provider + output,
        // remove the old one and keep this newer one.
        if let latest = translationHistory.first,
           latest.output == entry.output,
           latest.providerName == entry.providerName {
            translationHistory.removeFirst()
            // Also remove from actor's pending — will be cleaned on next flush
        }

        Task { await HistoryActor.shared.add(entry) }
        translationHistory.insert(entry, at: 0)

        let cap = maxHistoryCount
        if translationHistory.count > cap {
            translationHistory = Array(translationHistory.prefix(cap))
        }
    }

    func clearHistory() {
        translationHistory.removeAll()
        Task { await HistoryActor.shared.clear() }
    }

    /// Load full history on demand (called when user opens History tab).
    /// Triggers an actor reload from JSONL, then syncs the in-memory list
    /// from UserDefaults with dedup + cap applied.
    func loadFullHistory() {
        Task { await HistoryActor.shared.loadFromDisk() }
        translationHistory = ProviderStorageManager.loadHistory()
        let deduped = Self.deduplicateAdjacentEntries(translationHistory)
        translationHistory = Array(deduped.prefix(maxHistoryCount))
    }

    /// Trim history back to recent entries when leaving history tab
    func trimHistory() {
        let cap = maxHistoryCount
        if translationHistory.count > cap {
            translationHistory = Array(translationHistory.prefix(cap))
        }
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let input: String; let output: String
    let sourceLang: TranslationLanguage; let targetLang: TranslationLanguage
    let providerName: String; let model: String
    let timestamp: Date
    /// Whether context-aware translation was enabled when this entry was created.
    let isContextAwareEnabled: Bool
    /// Whether this was a dictionary-mode lookup (word → structured JSON).
    let isDictionaryMode: Bool
    /// Translation latency in milliseconds (nil if unavailable, e.g. cached).
    let durationMs: Int?
    /// Approximate token usage reported by the provider (nil if unavailable).
    let tokenCount: Int?
    /// Localized error message if the translation failed (nil on success).
    let errorMessage: String?

    init(input: String, output: String,
         sourceLang: TranslationLanguage, targetLang: TranslationLanguage,
         providerName: String, model: String,
         isContextAwareEnabled: Bool = false,
         isDictionaryMode: Bool = false,
         durationMs: Int? = nil,
         tokenCount: Int? = nil,
         errorMessage: String? = nil) {
        self.id = UUID(); self.input = input; self.output = output
        self.sourceLang = sourceLang; self.targetLang = targetLang
        self.providerName = providerName; self.model = model
        self.timestamp = Date()
        self.isContextAwareEnabled = isContextAwareEnabled
        self.isDictionaryMode = isDictionaryMode
        self.durationMs = durationMs
        self.tokenCount = tokenCount
        self.errorMessage = errorMessage
    }
}
