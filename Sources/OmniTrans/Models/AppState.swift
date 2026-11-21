import Foundation
import Carbon

let kAppVersion = "0.7.0"

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Set by `FloatingPanel` during window drag to signal `ThrottledStream`
    /// to relax its flush interval (80→120ms), avoiding main-thread contention
    /// between streaming renders and AppKit event tracking.
    @MainActor static var isUserDraggingWindow = false

    @Published var providers: [APIProvider] = []
    @Published var selectedProviderID: UUID?
    /// 查询模式手动覆盖（自动/取词/翻译）—— 面板底栏开关（修复2）。
    @Published var modeOverride: QueryModeOverride = .auto
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
    private var lastDictProviderID: UUID? = nil
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
        // 按存在性判断首次启动（keyCode 0 = A 键是合法值，审计 H8）
        if UserDefaults.standard.object(forKey: "hotkey_carbonKey") == nil {
            UserDefaults.standard.set(Int(kVK_ANSI_D), forKey: "hotkey_carbonKey")
            UserDefaults.standard.set(Int(optionKey), forKey: "hotkey_carbonMods")
        }
        if UserDefaults.standard.object(forKey: "ocr_hotkey_carbonKey") == nil {
            UserDefaults.standard.set(Int(kVK_ANSI_F), forKey: "ocr_hotkey_carbonKey")
            UserDefaults.standard.set(Int(optionKey), forKey: "ocr_hotkey_carbonMods")
        }
        if UserDefaults.standard.object(forKey: "replace_hotkey_carbonKey") == nil {
            UserDefaults.standard.set(Int(kVK_ANSI_R), forKey: "replace_hotkey_carbonKey")
            UserDefaults.standard.set(Int(optionKey), forKey: "replace_hotkey_carbonMods")
        }

        // Cache limits are configured inside TranslationCache / DictEntryCache init.
    }

    func load() {
        #if DEBUG
        SecretStore.debugDump()  // debug: verify keys on launch
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

    /// 防抖保存 pending 任务（编辑字段逐字符触发时合并为一次磁盘写入）。
    private var debouncedSaveItem: DispatchWorkItem?

    /// 防抖保存：合并短时间内的连续保存请求（默认 500ms 窗口）。
    /// 用于 `updateProvider` 这类逐字符触发的编辑路径。
    func scheduleDebouncedSave(interval: TimeInterval = 0.5) {
        debouncedSaveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        debouncedSaveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// 立即冲刷防抖保存（应用退出前调用，防止丢失未落盘的编辑）。
    func flushPendingSave() {
        debouncedSaveItem?.cancel()
        debouncedSaveItem = nil
        save()
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
            providers[i] = updated
            // 编辑字段逐字符触发 —— 防抖写盘，避免每键一次磁盘 IO。
            scheduleDebouncedSave()
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
        guard let p = selectedProvider, p.isEnabled else {
            // 纯原生词典查询不依赖云端 API 配置（P0-R4）；词典模式尊重手动覆盖（修复2）
            let treatAsWord = modeOverride == .dictionary
                || (modeOverride == .auto && WordDetector.isWord(text))
            if treatAsWord, enabledProviders.contains(where: { $0.kind == .macOSNative }) {
                session.isFromLocalCache = false
                doTranslate(text: text, provider: APIProvider.native, context: context, forceRefresh: forceRefresh)
                return
            }
            errorMessage = "请先选择并配置一个可用的 API"; return
        }

        // Reset local cache flags
        session.isFromLocalCache = false
        session.cachedModelName = ""
        session.cacheTimestamp = ""
        // 速率标签在每个新请求开始时隐藏（P2）
        session.tokenRate = nil
        session.ttft = nil

        // ── Cache gate ──
        let cacheOn = configuration.isCacheEnabled

        // ── Composite cache key: text + lang + provider + context-awareness state ──
        let cacheKey = Self.buildCacheKey(text: text, targetLang: targetLang, providerID: p.id, isContextAwareEnabled: configuration.isContextAwareEnabled, contextIntensity: configuration.contextIntensity, context: context) as NSString
        // forceRefresh（重试）必须绕过缓存与同文跳过（P0-3：旧实现导致重试按钮失效）
        if cacheOn, !forceRefresh, let cached = translationCache.get(cacheKey) {
            translatedText = cached
            isTranslating = false; streamingFinished = true
            showSuccessPulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                self?.showSuccessPulse = false
            }
            return
        }

        // Skip if nothing changed (same text, target, providers) — 重试除外（P0-3）
        // 修复3：词典源切换（dictProviderID 变化）也算"变了"，否则词典视图下切
        // API 后点翻译会被此处直接 return。
        if !forceRefresh, text == lastText, targetLang == lastTarget,
           selectedProviderID == lastProviderID, dictProviderID == lastDictProviderID,
           !translatedText.isEmpty { return }

        doTranslate(text: text, provider: p, context: context, forceRefresh: forceRefresh)
    }

    /// 原生词典结果统一入口：赋值 UI + 仅收录词缓存 L1。
    /// 未收录（isWord=false）也赋值——entry 携带「未收录」释义供 UI 展示；
    /// 但不缓存，避免本会话内永不重查（P0-R2）。
    @MainActor
    private func storeNativeDictionaryEntry(_ entry: DictionaryEntry, text: String, langKey: String) {
        dictionaryEntry = entry
        guard entry.isWord else { return }
        let dk = "\(text)_\(langKey)" as NSString
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = f.string(from: Date())
        dictEntryCache.set(entry, modelName: "macOS 词典", timestamp: ts, forKey: dk)
        // 新鲜原生查询 → 非本地缓存（P1-3 语义修正）
        session.isFromLocalCache = false
        session.cachedModelName = "macOS 词典"
        session.cacheTimestamp = ts
        // 归一化 JSON 落 L2 —— 冷启动不再重查 DCS，且与 AI 条目同 schema（P0-4）
        let normalized = Self.jsonString(for: entry)
        Task.detached(priority: .utility) {
            await LocalDictionaryRepository.shared.saveEntry(
                word: text, targetLang: langKey,
                modelName: "macOS 词典", jsonData: normalized, overwrite: false
            )
        }
    }

    /// 词典失败统一回退原生（JSON 解析失败 / 网络失败共用，P1-A）。
    @MainActor
    private func fallbackDictionaryToNative(text: String, langKey: String, provider: APIProvider) async {
        let entry = await MacOSNativeProvider.lookupWord(text)
        guard !Task.isCancelled else { return }
        storeNativeDictionaryEntry(entry, text: text, langKey: langKey)
        finishDictionaryLookup(historyJSON: Self.jsonString(for: entry),
                               text: text, provider: provider)
    }

    /// 词典收尾：结束态 + 历史。历史统一存 entry JSON ——
    /// native 旧实现存纯文本导致召回转词典模式时解码必失败（P1-A D7）。
    @MainActor
    private func finishDictionaryLookup(historyJSON: String, text: String, provider: APIProvider) {
        translatedText = ""
        isTranslating = false
        streamingFinished = true
        showSuccessPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.showSuccessPulse = false
        }
        addHistory(text: text, result: historyJSON, provider: provider)
        isDictionaryMode = false
    }

    /// 双源字段合并（D9）：释义/例句以 AI 为准；音标/音标变体/变形词
    /// AI 缺失时用 native 补缺（native 独有 phoneticVariants/inflections）。
    /// 纯函数部分在 AppState+TranslationLogic（P1-3，可单测）。
    @MainActor
    private func mergeNativeDictionaryFields(into entry: DictionaryEntry, word: String) async -> DictionaryEntry {
        let native = await MacOSNativeProvider.lookupWord(word)
        return Self.merged(ai: entry, native: native)
    }

    private static func jsonString(for entry: DictionaryEntry) -> String {
        guard let data = try? JSONEncoder().encode(entry),
              let s = String(data: data, encoding: .utf8) else { return entry.word }
        return s
    }

    private static func nowTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    @MainActor
    private func doTranslate(text: String, provider: APIProvider, context: CapturedContext? = nil, forceRefresh: Bool = false, fallbackDepth: Int = 0) {
        activeStreamTask?.cancel()
        isTranslating = true; errorMessage = nil; translatedText = ""
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false; showErrorPulse = false
        session.tokenRate = nil
        session.ttft = nil
        // 修复3：记录上一轮的翻译源与词典源，用于判定"用户切换了 API"
        let previousProviderID = lastProviderID
        let previousDictProviderID = lastDictProviderID
        lastText = text; lastTarget = targetLang
        lastProviderID = selectedProviderID
        lastDictProviderID = dictProviderID
        let providerChanged = previousProviderID != nil
            && (previousProviderID != selectedProviderID || previousDictProviderID != dictProviderID)

        activeStreamTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            // Probe is deferred to FallbackRouter.resolveWithFallback() only on
            // failure — uses lightweight HEAD request (M2), consuming no API quota.
            // Success path skips probe entirely for minimum latency.
            // 查询模式（修复2）：手动覆盖优先于自动判定
            let isWord: Bool
            switch self.modeOverride {
            case .auto:        isWord = WordDetector.isWord(text)
            case .dictionary:  isWord = true
            case .translation: isWord = false
            }

            let effectiveProvider: APIProvider
            if isWord {
                if let dictID = self.dictProviderID,
                   let dictProvider = self.enabledProviders.first(where: { $0.id == dictID }) {
                    effectiveProvider = dictProvider
                } else if let aiProvider = self.enabledProviders.first(where: { !$0.kind.isTraditionalMT }) {
                    // 词典源失效（禁用/删除）→ 回落首个可用非 MT 引擎，
                    // 而非 selectedProvider（可能是 MT，永不进词典模式）（P0-R4）
                    effectiveProvider = aiProvider
                } else {
                    effectiveProvider = provider
                }
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

            // ── 上下文感知标记: 当上下文可用且上下文感知开启时，
            //    缓存键追加 "_ctx" 后缀以区分上下文感知与非上下文感知的结果。
            //    这确保语境含义不同的同词查询能得到各自对应的词典结果。
            let isContextActive = context?.hasContext == true && configuration.isContextAwareEnabled

            // ── L1 内存缓存 (最快, 零 I/O) ──
            // 修复3：切换 API 后绕过 provider 无关的词典缓存，强制新请求
            if isDict, !forceRefresh, !providerChanged, cacheEnabled, !isContextActive {
                let l1Key = "\(text)_\(langKey)" as NSString
                if let cachedEntry = dictEntryCache.get(l1Key) {
                    self.dictionaryEntry = cachedEntry
                    self.isDictionaryMode = true
                    self.isTranslating = false
                    self.session.isFromLocalCache = true
                    // 恢复 L1 元数据 (modelName|timestamp)
                    if let meta = dictEntryCache.getMeta(l1Key) {
                        let parts = meta.split(separator: "|", maxSplits: 1)
                        self.session.cachedModelName = parts.count > 0 ? String(parts[0]) : ""
                        self.session.cacheTimestamp = parts.count > 1 ? String(parts[1]) : ""
                    } else {
                        self.session.cachedModelName = ""
                        self.session.cacheTimestamp = ""
                    }
                    self.streamingFinished = true
                    self.showSuccessPulse = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                        self?.showSuccessPulse = false
                    }
                    self.addHistory(text: text, result: Self.jsonString(for: cachedEntry), provider: effectiveProvider)
                    self.isDictionaryMode = false
                    return
                }
            }

            // ── L2 SQLite 持久缓存 (磁盘 I/O, 命中后预热 L1) ──
            // 修复3：切换 API 后绕过（同上）
            if isDict, !forceRefresh, !providerChanged, cacheEnabled, !isContextActive {
                if let cached = await LocalDictionaryRepository.shared.fetchEntry(word: text, targetLang: langKey) {
                    if let entry = DictionaryEntry.parse(from: cached.jsonData, word: text) {
                        // Warm L1 — 后续查询零 I/O 直接命中内存
                        let l1Key = "\(text)_\(langKey)" as NSString
                        self.dictEntryCache.set(entry, modelName: cached.modelName, timestamp: cached.timestamp, forKey: l1Key)
                        // Populate UI
                        self.dictionaryEntry = entry
                        self.isDictionaryMode = true
                        self.isTranslating = false
                        self.session.isFromLocalCache = true
                        self.session.cachedModelName = cached.modelName
                        self.session.cacheTimestamp = cached.timestamp
                        self.streamingFinished = true
                        self.showSuccessPulse = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                            self?.showSuccessPulse = false
                        }
                        self.addHistory(text: text, result: cached.jsonData, provider: effectiveProvider)
                        self.isDictionaryMode = false
                        return
                    }
                    // 坏行自愈（P1-A）：存量 JSON 无法解析 → 删除，本次走网络重查并重新落库
                    await LocalDictionaryRepository.shared.deleteEntry(word: text, targetLang: langKey)
                }
            }

            // 词典 + native 源：直接结构化查询，不再走引擎流 + 二次查询（P1-A D2）
            if isDict, effectiveProvider.kind == .macOSNative {
                self.isDictionaryMode = true
                let entry = await MacOSNativeProvider.lookupWord(text)
                guard !Task.isCancelled else { return }
                self.storeNativeDictionaryEntry(entry, text: text, langKey: langKey)
                self.finishDictionaryLookup(historyJSON: Self.jsonString(for: entry),
                                            text: text, provider: effectiveProvider)
                return
            }

            // 速率测量（P2）：仅 AI 流式；传统 MT / native / 词典不显示标签
            let measureTokenRate = !isDict && !effectiveProvider.kind.isTraditionalMT
                && effectiveProvider.kind != .macOSNative
            var rateMeter = TokenRateMeter()

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

            // ── 收集全部 chunk（词典：一次性解析；翻译：增量拼接渲染）──
            var chunks: [String] = []
            chunks.reserveCapacity(64)
            // P1-1：增量累加替代每批 chunks.joined() 的全量重拼
            var rendered = ""

            do {
                for try await batch in stream {
                    chunks.append(batch)
                    if !isDict {
                        // @MainActor Task — direct update, no actor hop needed
                        rendered += batch
                        self.translatedText = rendered
                        if measureTokenRate, rateMeter.feed(batch) {
                            self.session.tokenRate = rateMeter.rate
                            self.session.ttft = rateMeter.ttft
                        }
                    }
                }
                if !isDict, chunks.isEmpty {
                    self.translatedText = ""
                }

                // ── Cache successful result (composite key, 仅用于非词典模式) ──
                if !isDict, self.configuration.isCacheEnabled {
                    let ck = Self.buildCacheKey(text: text, targetLang: self.targetLang, providerID: effectiveProvider.id, isContextAwareEnabled: self.configuration.isContextAwareEnabled, contextIntensity: self.configuration.contextIntensity, context: context) as NSString
                    self.translationCache.set(rendered, forKey: ck)
                }

                if isDict {
                    // 单次解析（P1-A：废弃增量解析，消除 O(n²) 重解析与
                    // lastValidDictionaryJson 硬锁定 hack）
                    guard !Task.isCancelled else { return }
                    let fullText = chunks.joined()
                    guard let entry = DictionaryEntry.parse(from: fullText, word: text) else {
                        NetworkLogger.log("DictFallback", "AI JSON parse failed — switching to native")
                        await self.fallbackDictionaryToNative(text: text, langKey: langKey, provider: effectiveProvider)
                        return
                    }
                    // 双源字段合并（D9）：释义/例句以 AI 为准，音标/变形 native 补缺
                    let merged = await self.mergeNativeDictionaryFields(into: entry, word: text)
                    guard !Task.isCancelled else { return }
                    self.dictionaryEntry = merged
                    let aiModel = effectiveProvider.modelName
                    let tsAI = Self.nowTimestamp()
                    // 新鲜网络结果 → 非"本地缓存"（P1-3：旧实现误标 fromCache=true，
                    // UI 会显示"由 X 生成于 Y"缓存徽标）
                    self.session.isFromLocalCache = false
                    self.session.cachedModelName = aiModel
                    self.session.cacheTimestamp = tsAI
                    // 归一化 JSON（含双源合并字段），与 L1/历史/召回同 schema（P0-4）
                    let normalized = Self.jsonString(for: merged)
                    // 缓存键读写对齐（P1-3）：上下文感知结果不写 L1/L2（读取侧本就跳过），
                    // 消除永不命中的 `_ctx` 键。
                    if !isContextActive {
                        let dk = "\(text)_\(langKey)" as NSString
                        self.dictEntryCache.set(merged, modelName: aiModel, timestamp: tsAI, forKey: dk)
                        if merged.isWord {
                            Task.detached(priority: .utility) {
                                await LocalDictionaryRepository.shared.saveEntry(
                                    word: text, targetLang: langKey,
                                    modelName: aiModel, jsonData: normalized,
                                    // 切换 API 后的新结果应覆盖旧条目（否则重启后仍显示旧 API 结果）
                                    overwrite: forceRefresh || providerChanged
                                )
                            }
                        }
                    }
                    self.finishDictionaryLookup(historyJSON: normalized, text: text, provider: effectiveProvider)
                    return
                } else {
                    self.dictionaryEntry = nil
                }

                // 成功路径同样检查取消：旧任务挂起恢复后不得覆盖新请求状态（P0-R5）
                guard !Task.isCancelled else { return }

                // 完成时冻结为整体均值（排除首字延迟）（P2）；
                // OpenAI 系有真实 usage 时优先用 completion_tokens 校准（backlog）
                if measureTokenRate {
                    let actualTokens = await TranslationActor.shared.lastCompletionTokens
                    self.session.tokenRate = rateMeter.finalRate(actualTokens: actualTokens)
                        ?? rateMeter.finalRate()
                        ?? rateMeter.rate
                    self.session.ttft = rateMeter.ttft
                }

                // ── End translation AFTER dictionaryEntry is set ──
                // Must come after dictionaryEntry assignment so SwiftUI
                // never observes isTranslating=false while dictionaryEntry
                // is still nil (would render blank Spacer in middleArea).
                self.isTranslating = false
                self.streamingFinished = true
                self.showSuccessPulse = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    self?.showSuccessPulse = false
                }
                // ⚠️ addHistory must be called BEFORE isDictionaryMode reset,
                // otherwise HistoryEntry.isDictionaryMode is always false
                self.addHistory(text: text, result: rendered, provider: effectiveProvider)
                self.isDictionaryMode = false
            } catch {
                // 被取消的旧请求不得降级/重试，避免旧结果覆盖新译文（审计 H1）
                if error is CancellationError || Task.isCancelled { return }
                NetworkLogger.logError("Stream", error)

                if isDict {
                    // 词典流式请求失败 → 统一回退原生词典（解析失败路径已在流内处理）
                    NetworkLogger.log("DictFallback", "stream failed — switching to native")
                    await self.fallbackDictionaryToNative(text: text, langKey: langKey, provider: effectiveProvider)
                    return
                }

                // 回退默认启用（P0-R3：fallback_on_failure 全仓库无写入点恒 false，
                // 等价于功能不存在；深度上限已由 H1 保护）
                let errStr = error.localizedDescription.lowercased()
                let isAuthError = errStr.contains("401") || errStr.contains("403") || errStr.contains("unauthorized") || errStr.contains("invalid api key") || errStr.contains("key 无效")

                NetworkLogger.log("Fallback", "isAuth=\(isAuthError) error=\(error.localizedDescription.prefix(80))")

                // 深度上限：每个 provider 至多尝试一次，防止全失败时取模回绕无限递归（审计 H1）
                if !isAuthError, fallbackDepth < self.enabledProviders.count,
                   let next = Self.nextFallbackProvider(after: effectiveProvider, in: self.enabledProviders) {
                    NetworkLogger.log("Fallback", "switching \(effectiveProvider.name) → \(next.name)")
                    self.selectedProviderID = next.id
                    ProviderStorageManager.saveSelectedProviderID(next.id)
                    self.doTranslate(text: text, provider: next, context: context, fallbackDepth: fallbackDepth + 1)
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                            self?.showSuccessPulse = false
                        }
                        self.addHistory(text: text, result: r.text, provider: effectiveProvider)
                    } catch {
                        NetworkLogger.logError("NonStreamingFallback", error)
                        let msg = error.localizedDescription
                        self.errorMessage = msg
                        self.isTranslating = false
                        self.showErrorShake = true
                        self.showErrorPulse = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                            self?.showErrorPulse = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                            self?.showErrorShake = false
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
        // 新的取词/打开窗口 → 模式覆盖回到自动（修复2）
        modeOverride = .auto
        streamingFinished = false; showSuccessPulse = false; showErrorShake = false; showErrorPulse = false
        showPermissionHint = !HotkeyManager.isTrusted && text.isEmpty

        // Pre-allocate translatedText buffer: translations are typically 1×–3× source length.
        // This avoids ~log₂(N) heap reallocations during streaming token concatenation.
        session.translatedText.reserveCapacity(max(1024, text.count * 2))

        // 刻意不做延迟内存清理：resetForNew 在每次翻译/OCR 后都会触发，
        // malloc_zone_pressure_relief 会把 Vision 内部缓冲反复「清零」导致下次识别冷建
        // （连续识别卡死主因之一）。清理职责收归系统内存压力事件统一处理。
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
