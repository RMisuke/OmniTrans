import Foundation
import os

/// Static proxy for persistent storage.  Loads providers from UserDefaults,
/// fills secret fields from an in-memory cache (populated once from Keychain),
/// and persists everything on save.
///
/// Keychain model: one JSON blob per provider stored at account `provider:{uuid}`.
enum ProviderStorageManager {
    private enum Key {
        static let providers = "saved_providers_v3"
        static let dictProviderID = "dict_provider_id"
        static let selectedProviderID = "selected_provider_id"
        static let sourceLang = "source_lang"
        static let targetLang = "target_lang"
        static let history = "translation_history"
    }

    // ── In-memory secret cache (thread-safe via OSAllocatedUnfairLock) ──
    fileprivate static let cacheLock = OSAllocatedUnfairLock(initialState: (
        cache: [UUID: KeychainFields](),
        loaded: false
    ))

    // MARK: - Cache

    static func preloadSecrets() {
        cacheLock.withLock { state in
            guard !state.loaded else { return }
            state.cache = KeychainManager.batchReadAll()
            state.loaded = true
        }
    }

    static func cachedFields(for providerID: UUID) -> KeychainFields {
        cacheLock.withLock { state in
            state.cache[providerID] ?? KeychainFields()
        }
    }

    /// Single field lookup from cache — zero Keychain I/O.
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

    // MARK: - Providers

    static func loadProviders() -> [APIProvider] {
        #if DEBUG
        print("[Storage] loadProviders called")
        #endif
        preloadSecrets()
        guard let data = UserDefaults.standard.data(forKey: Key.providers),
              let decoded = try? JSONDecoder().decode([APIProvider].self, from: data)
        else { return [] }

        var providers = decoded
        for i in providers.indices {
            let fields = cacheLock.withLock { state in state.cache[providers[i].id] ?? KeychainFields() }
            if providers[i].apiKey.isEmpty && !fields.apiKey.isEmpty {
                providers[i].apiKey = fields.apiKey
            }
            if providers[i].apiSecret.isEmpty && !fields.apiSecret.isEmpty {
                providers[i].apiSecret = fields.apiSecret
            }
            if providers[i].customRegion.isEmpty && !fields.customRegion.isEmpty {
                providers[i].customRegion = fields.customRegion
            }
        }
        return providers
    }

    static func saveProviders(_ providers: [APIProvider]) {
        #if DEBUG
        print("[Storage] saveProviders called with \(providers.count) providers")
        for p in providers {
            print("[Storage]   provider \(p.name) (id=\(p.id)) apiKey=\(p.apiKey.prefix(6))... secret=\(p.apiSecret.prefix(6))...")
        }
        #endif
        for p in providers {
            let fields = KeychainFields(
                apiKey: p.apiKey,
                apiSecret: p.apiSecret,
                customRegion: p.customRegion
            )
            if !fields.isEmpty {
                KeychainManager.saveFields(fields, for: p.id)
                _ = cacheLock.withLock { state in state.cache[p.id] = fields }
            } else {
                KeychainManager.deleteAllFields(for: p.id)
                _ = cacheLock.withLock { state in state.cache.removeValue(forKey: p.id) }
            }
        }

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

    static func deleteProviderSecrets(for id: UUID) {
        KeychainManager.deleteAllFields(for: id)
        _ = cacheLock.withLock { state in state.cache.removeValue(forKey: id) }
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

    // MARK: - Dict provider

    static func loadDictProviderID() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: Key.dictProviderID),
              let uuid = UUID(uuidString: str) else { return nil }
        return uuid
    }
    static func saveDictProviderID(_ id: UUID?) {
        UserDefaults.standard.set(id?.uuidString, forKey: Key.dictProviderID)
    }

    // MARK: - Selected provider (translation engine persistence)

    static func loadSelectedProviderID() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: Key.selectedProviderID),
              let uuid = UUID(uuidString: str) else { return nil }
        return uuid
    }
    static func saveSelectedProviderID(_ id: UUID?) {
        UserDefaults.standard.set(id?.uuidString, forKey: Key.selectedProviderID)
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
