import Foundation

// MARK: - Translation Cache

/// Thread-safe in-memory translation cache for non-dictionary results.
/// Accessed only from `@MainActor` via `AppState`.
final class TranslationCache: @unchecked Sendable {
    private let inner = NSCache<NSString, NSString>()

    init() { inner.countLimit = 200 }

    func get(_ key: NSString) -> String? { inner.object(forKey: key) as String? }
    func set(_ value: String, forKey key: NSString) { inner.setObject(value as NSString, forKey: key) }
}

// MARK: - Dictionary Entry Cache

/// In-memory dictionary lookup cache — keyed by lowercased word + provider ID.
/// Accessed only from `@MainActor` via `AppState`.
final class DictEntryCache: @unchecked Sendable {
    final class Box { let entry: DictionaryEntry; init(_ e: DictionaryEntry) { entry = e } }
    private let inner = NSCache<NSString, Box>()

    init() { inner.countLimit = 200 }

    func get(_ key: NSString) -> DictionaryEntry? { inner.object(forKey: key)?.entry }
    func set(_ entry: DictionaryEntry, forKey key: NSString) { inner.setObject(Box(entry), forKey: key) }
}
