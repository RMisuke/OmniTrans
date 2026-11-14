import Foundation
import os

// MARK: - Provider Storage Manager

/// 供应商配置持久化代理。采用分层架构：
///
/// - **Keychain / 加密文件**：存储敏感字段（apiKey, apiSecret, customRegion）
/// - **UserDefaults**：存储非敏感配置（名称、模型、启用状态等）
/// - **内存缓存**：启动时一次性加载密钥，后续读取零 I/O
///
/// ## 性能设计
/// - `saveProviders` 采用增量写入：仅变更的 provider 触发 Keychain I/O
/// - 内存缓存通过 `OSAllocatedUnfairLock` 保证线程安全
/// - UserDefaults 写入保持原子性（JSON 编码后整体替换）
enum ProviderStorageManager {

    private static let log = OSLog(subsystem: AppLogging.subsystem, category: "Storage")

    // MARK: - Storage Keys

    private enum Key {
        static let providers       = "saved_providers_v3"
        static let dictProviderID  = "dict_provider_id"
        static let selectedProviderID = "selected_provider_id"
        static let sourceLang      = "source_lang"
        static let targetLang      = "target_lang"
        static let history         = "translation_history"
    }

    // MARK: - In-Memory Secret Cache

    /// 线程安全的密钥缓存。启动时从 Keychain 一次性加载，
    /// 后续 `cachedValue` 调用零磁盘 I/O。
    fileprivate static let cacheLock = OSAllocatedUnfairLock(initialState: (
        cache: [UUID: KeychainFields](),
        loaded: false
    ))

    // MARK: - Cache Management

    /// 预加载密钥到内存缓存（仅首次调用触发 Keychain 读取）。
    static func preloadSecrets() {
        cacheLock.withLock { state in
            guard !state.loaded else { return }
            state.cache = KeychainManager.batchReadAll()
            state.loaded = true
        }
    }

    /// 获取指定 provider 的密钥字段（零 I/O）。
    static func cachedFields(for providerID: UUID) -> KeychainFields {
        cacheLock.withLock { $0.cache[providerID] ?? KeychainFields() }
    }

    /// 单字段查找（零 I/O）—— 供翻译链路高频调用。
    static func cachedValue(for providerID: UUID, field: String) -> String {
        cacheLock.withLock { state in
            let f = state.cache[providerID] ?? KeychainFields()
            switch field {
            case "apiKey":    return f.apiKey
            case "apiSecret": return f.apiSecret
            case "region":    return f.customRegion
            default:          return ""
            }
        }
    }

    // MARK: - Providers (Load)

    /// 从 UserDefaults 加载供应商配置，并从内存缓存填充密钥字段。
    static func loadProviders() -> [APIProvider] {
        preloadSecrets()

        guard let data = UserDefaults.standard.data(forKey: Key.providers),
              let decoded = try? JSONDecoder().decode([APIProvider].self, from: data)
        else { return [] }

        // 从缓存合并密钥（避免 Keychain I/O）
        return cacheLock.withLock { state in
            decoded.map { provider in
                var p = provider
                let fields = state.cache[p.id] ?? KeychainFields()
                if p.apiKey.isEmpty && !fields.apiKey.isEmpty { p.apiKey = fields.apiKey }
                if p.apiSecret.isEmpty && !fields.apiSecret.isEmpty { p.apiSecret = fields.apiSecret }
                if p.customRegion.isEmpty && !fields.customRegion.isEmpty { p.customRegion = fields.customRegion }
                return p
            }
        }
    }

    // MARK: - Providers (Save) — Incremental

    /// 增量保存供应商配置。
    ///
    /// **优化策略**：
    /// 1. 仅对密钥字段变更的 provider 执行 Keychain I/O（增量写入）
    /// 2. 非敏感配置统一写入 UserDefaults（原子替换）
    /// 3. 内存缓存同步更新，保证后续读取一致性
    static func saveProviders(_ providers: [APIProvider]) {
        #if DEBUG
        os_log(.debug, log: log, "saveProviders called with %d providers", providers.count)
        #endif

        // ── Step 1: 增量 Keychain 写入（仅变更项） ──
        for p in providers {
            let newFields = KeychainFields(
                apiKey: p.apiKey,
                apiSecret: p.apiSecret,
                customRegion: p.customRegion
            )
            let oldFields = cacheLock.withLock { $0.cache[p.id] ?? KeychainFields() }

            // 仅当密钥内容发生变化时才触发 Keychain I/O
            guard newFields.apiKey != oldFields.apiKey
                    || newFields.apiSecret != oldFields.apiSecret
                    || newFields.customRegion != oldFields.customRegion
            else { continue }

            if !newFields.isEmpty {
                KeychainManager.saveFields(newFields, for: p.id)
                cacheLock.withLock { $0.cache[p.id] = newFields }
            } else {
                KeychainManager.deleteAllFields(for: p.id)
                _ = cacheLock.withLock { $0.cache.removeValue(forKey: p.id) }
            }
        }

        // ── Step 2: 写入非敏感配置到 UserDefaults ──
        var sanitized = providers
        for i in sanitized.indices {
            sanitized[i].apiKey = ""
            sanitized[i].apiSecret = ""
            sanitized[i].customRegion = ""
        }
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: Key.providers)
        }
    }

    /// 删除指定 provider 的密钥（从 Keychain + 缓存中移除）。
    static func deleteProviderSecrets(for id: UUID) {
        KeychainManager.deleteAllFields(for: id)
        _ = cacheLock.withLock { $0.cache.removeValue(forKey: id) }
    }

    // MARK: - Languages

    static func loadSourceLang() -> TranslationLanguage {
        guard let raw = UserDefaults.standard.string(forKey: Key.sourceLang),
              let lang = TranslationLanguage(rawValue: raw) else { return .auto }
        return lang
    }

    static func saveSourceLang(_ lang: TranslationLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: Key.sourceLang)
    }

    static func loadTargetLang() -> TranslationLanguage {
        guard let raw = UserDefaults.standard.string(forKey: Key.targetLang),
              let lang = TranslationLanguage(rawValue: raw), lang != .auto else { return .chinese }
        return lang
    }

    static func saveTargetLang(_ lang: TranslationLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: Key.targetLang)
    }

    // MARK: - Provider Selection

    static func loadSelectedProviderID() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: Key.selectedProviderID),
              let uuid = UUID(uuidString: str) else { return nil }
        return uuid
    }

    static func saveSelectedProviderID(_ id: UUID?) {
        UserDefaults.standard.set(id?.uuidString, forKey: Key.selectedProviderID)
    }

    static func loadDictProviderID() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: Key.dictProviderID),
              let uuid = UUID(uuidString: str) else { return nil }
        return uuid
    }

    static func saveDictProviderID(_ id: UUID?) {
        UserDefaults.standard.set(id?.uuidString, forKey: Key.dictProviderID)
    }

    // MARK: - History

    static func loadRecentHistory(limit: Int = 20) -> [HistoryEntry] {
        guard let d = UserDefaults.standard.data(forKey: Key.history) else { return [] }
        let all = (try? JSONDecoder().decode([HistoryEntry].self, from: d)) ?? []
        return Array(all.prefix(limit))
    }

    static func loadHistory() -> [HistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: Key.history),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return decoded
    }

    static func saveHistory(_ entries: [HistoryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Key.history)
        }
    }

    static func clearHistory() {
        UserDefaults.standard.removeObject(forKey: Key.history)
    }
}
