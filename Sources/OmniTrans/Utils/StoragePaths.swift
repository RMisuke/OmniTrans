import Foundation

// MARK: - Application Support Paths

/// `~/Library/Application Support/OmniTrans` 路径的唯一来源。
///
/// 所有持久化子系统（KeychainManager、HistoryActor、LocalDictionaryRepository）
/// 统一使用此类型，避免路径构造和目录创建逻辑的重复。
///
/// ## 性能设计
/// `appSupportDir` 启动时一次性创建并缓存，后续访问零文件系统调用。
enum StoragePaths {

    /// 缓存的 Application Support 目录 URL（进程生命周期内不变）。
    private static let cachedDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniTrans")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Application Support/OmniTrans 目录。
    static var appSupportDir: URL { cachedDir }

    /// 加密密钥文件路径。
    static var secretsFile: URL {
        appSupportDir.appendingPathComponent("secrets.json")
    }

    /// JSONL 翻译历史归档路径。
    static var historyArchive: URL {
        appSupportDir.appendingPathComponent("history_archive.jsonl")
    }

    /// SQLite 词典缓存数据库路径。
    static var dictionaryDB: URL {
        appSupportDir.appendingPathComponent("dictionary_cache.db")
    }

    /// SQLite 数据库的 POSIX 路径字符串。
    static var dictionaryDBPath: String {
        dictionaryDB.path
    }
}
