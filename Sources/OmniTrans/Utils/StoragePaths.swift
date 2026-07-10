import Foundation

// MARK: - Unified Application Support Paths

/// Single source of truth for all `~/Library/Application Support/OmniTrans` paths.
///
/// All three subsystems that need persistent storage (KeychainManager,
/// HistoryActor, LocalDictionaryRepository) use this type to avoid
/// duplicating path construction and directory-creation logic.
enum StoragePaths {

    /// Absolute URL of the `OmniTrans` directory under `Application Support`.
    /// Creates the directory if it does not exist.
    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniTrans")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Absolute path to the encrypted secrets file.
    static var secretsFile: URL {
        appSupportDir.appendingPathComponent("secrets.json")
    }

    /// Absolute path to the JSONL history archive.
    static var historyArchive: URL {
        appSupportDir.appendingPathComponent("history_archive.jsonl")
    }

    /// Absolute path to the SQLite dictionary cache database.
    static var dictionaryDB: URL {
        appSupportDir.appendingPathComponent("dictionary_cache.db")
    }

    /// Convenience: returns the POSIX path string for `dictionaryDB`.
    static var dictionaryDBPath: String {
        dictionaryDB.path
    }
}
