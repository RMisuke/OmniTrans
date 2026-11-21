import Foundation
import OSLog
import SQLite3

/// M8: DB 日志统一走 OSLog（subsystem 统一），避免 print 噪音。
private let dictRepoLog = OSLog(subsystem: AppLogging.subsystem, category: "DictRepo")

// MARK: - Safe SQLite Destructor

/// `SQLITE_TRANSIENT` — tells SQLite to copy string data before the statement is finalized.
/// Using this named constant instead of `unsafeBitCast(-1, ...)` avoids undefined behaviour
/// from reinterpret-casting an integer to a function pointer.
private let SQLITE_TRANSIENT_COPY = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Local Dictionary Repository (SQLite-backed)

/// Thread-safe actor wrapping a local SQLite database for offline dictionary caching.
///
/// ## Design Philosophy
/// This is a **personal dictionary database** — entries are written once and
/// kept permanently.  The cache is keyed only by `(query_word, target_lang)`,
/// independent of which AI provider generated the entry.  Once a word has
/// been looked up, all subsequent queries (even with different providers)
/// return the cached result instantly — zero network cost.
///
/// Only a user's explicit **re‑lookup** action (`forceRefresh = true`) will
/// overwrite an existing entry.  The `model_name` column stores metadata
/// about which model generated the entry, purely for display purposes.
actor LocalDictionaryRepository {
    /// Returns an ISO8601 timestamp string with the current local timezone offset.
    /// Example: `"2026-07-10T12:30:00+08:00"`
    /// This ensures the timestamp is always stored with proper timezone context,
    /// avoiding the UTC-vs-local mismatch that `CURRENT_TIMESTAMP` causes.
    // ISO8601DateFormatter 格式化是线程安全的；仅 actor 内使用（非隔离标注消除告警）
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func localTimestampString() -> String {
        timestampFormatter.string(from: Date())
    }
    static let shared = LocalDictionaryRepository()

    /// NULL 安全的列读取（backlog：sqlite3_column_text 返回 NULL 时
    /// String(cString:) 会崩溃，如列被写空/NULL 的异常行）。
    private static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private var db: OpaquePointer?

    /// Synchronous initializer — runs before the actor accepts any messages
    /// on its executor, so direct SQLite calls are safe and there is no
    /// race between `fetchEntry`/`saveEntry` and database setup.
    private init() {
        let dbPath = StoragePaths.dictionaryDBPath

        var handle: OpaquePointer?
        guard sqlite3_open(dbPath, &handle) == SQLITE_OK else {
            os_log(.error, log: dictRepoLog, "Failed to open database at %{public}@", dbPath)
            self.db = nil
            return
        }
        // Enable WAL mode for concurrent reads
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil)
        os_log(.debug, log: dictRepoLog, "Opened at %{public}@", dbPath)

        // Create schema
        let sql = """
        CREATE TABLE IF NOT EXISTS custom_dictionary (
            query_word   TEXT NOT NULL,
            target_lang  TEXT NOT NULL,
            model_name   TEXT NOT NULL,
            json_data    TEXT NOT NULL,
            updated_at   DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_dict_query
            ON custom_dictionary(query_word, target_lang);
        CREATE INDEX IF NOT EXISTS idx_dict_updated
            ON custom_dictionary(updated_at DESC);
        """
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            os_log(.error, log: dictRepoLog, "Schema creation failed")
        }
        self.db = handle
    }

    // MARK: - Public API

    /// Fetches a cached entry. Returns `nil` on cache miss.
    func fetchEntry(word: String, targetLang: String) -> CachedDictEntry? {
        guard let db else { return nil }
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql = "SELECT model_name, json_data, updated_at FROM custom_dictionary WHERE query_word = ? AND target_lang = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_COPY)
        sqlite3_bind_text(stmt, 2, targetLang, -1, SQLITE_TRANSIENT_COPY)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let model = Self.columnString(stmt, 0)
        let json  = Self.columnString(stmt, 1)
        let ts    = Self.columnString(stmt, 2)

        return CachedDictEntry(modelName: model, jsonData: json, timestamp: ts)
    }

    /// 删除一条缓存（坏数据自愈用，P1-A：存量坏 JSON 删除后由本次网络重查覆盖）。
    func deleteEntry(word: String, targetLang: String) {
        guard let db else { return }
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql = "DELETE FROM custom_dictionary WHERE query_word = ? AND target_lang = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_COPY)
        sqlite3_bind_text(stmt, 2, targetLang, -1, SQLITE_TRANSIENT_COPY)
        sqlite3_step(stmt)
    }

    /// Saves a dictionary entry with **write‑once** semantics by default.
    ///
    /// - Parameter overwrite: When `false` (default), uses `INSERT OR IGNORE` —
    ///   existing entries are never touched.  Only set this to `true` when the
    ///   user explicitly requests a re‑lookup (force refresh).
    func saveEntry(word: String, targetLang: String, modelName: String, jsonData: String, overwrite: Bool = false) {
        guard let db else { return }
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let ts = Self.localTimestampString()

        let sql: String
        if overwrite {
            sql = """
            INSERT INTO custom_dictionary (query_word, target_lang, model_name, json_data, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(query_word, target_lang) DO UPDATE SET
                model_name = excluded.model_name,
                json_data  = excluded.json_data,
                updated_at = ?
            """
        } else {
            sql = """
            INSERT OR IGNORE INTO custom_dictionary (query_word, target_lang, model_name, json_data, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_COPY)
        sqlite3_bind_text(stmt, 2, targetLang, -1, SQLITE_TRANSIENT_COPY)
        sqlite3_bind_text(stmt, 3, modelName, -1, SQLITE_TRANSIENT_COPY)
        sqlite3_bind_text(stmt, 4, jsonData, -1, SQLITE_TRANSIENT_COPY)
        if overwrite {
            sqlite3_bind_text(stmt, 5, ts, -1, SQLITE_TRANSIENT_COPY)
            sqlite3_bind_text(stmt, 6, ts, -1, SQLITE_TRANSIENT_COPY)
        } else {
            sqlite3_bind_text(stmt, 5, ts, -1, SQLITE_TRANSIENT_COPY)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            os_log(.error, log: dictRepoLog, "Save failed: %{public}@", String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Deletes all rows (destructive wipe).
    func deleteAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM custom_dictionary", nil, nil, nil)
    }

    /// Batch import CSV rows with conflict strategy.
    /// Returns the number of rows that failed to import.
    /// RFC4180 最小 CSV 行解析：引号包裹字段 + `""` 转义（P0-5）。
    /// 旧实现 `components(separatedBy: ",")` 会在 json_data 含逗号时截断，
    /// 坏行随后被自愈逻辑删除 → 导入数据静默丢失。
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if inQuotes {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    @discardableResult
    func batchImport(lines: [String], overwrite: Bool) -> Int {
        guard let db else { return lines.count }
        let ts = Self.localTimestampString()
        let conflictStrategy = overwrite
            ? "ON CONFLICT(query_word, target_lang) DO UPDATE SET model_name=excluded.model_name, json_data=excluded.json_data, updated_at=?"
            : "ON CONFLICT(query_word, target_lang) DO NOTHING"
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        // P8: 事务内只 prepare 一次，逐行 reset+rebind，避免每行重复 prepare 的开销
        let sql = "INSERT INTO custom_dictionary (query_word, target_lang, model_name, json_data, updated_at) VALUES (?, ?, ?, ?, ?) \(conflictStrategy)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return lines.count
        }
        defer { sqlite3_finalize(stmt) }

        var errorCount = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let cols = Self.parseCSVLine(line)
            guard cols.count >= 4 else { errorCount += 1; continue }
            let word   = cols[0]
            let lang   = cols[1]
            let model  = cols[2]
            let json   = cols[3]

            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT_COPY)
            sqlite3_bind_text(stmt, 2, lang, -1, SQLITE_TRANSIENT_COPY)
            sqlite3_bind_text(stmt, 3, model, -1, SQLITE_TRANSIENT_COPY)
            sqlite3_bind_text(stmt, 4, json, -1, SQLITE_TRANSIENT_COPY)
            sqlite3_bind_text(stmt, 5, ts, -1, SQLITE_TRANSIENT_COPY)
            if overwrite {
                sqlite3_bind_text(stmt, 6, ts, -1, SQLITE_TRANSIENT_COPY)
            }
            if sqlite3_step(stmt) != SQLITE_DONE { errorCount += 1 }
        }
        // 全部失败 → 回滚（backlog：旧实现始终 COMMIT，空事务也提交）
        if errorCount > 0 && errorCount >= lines.count {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            os_log(.error, log: dictRepoLog, "batchImport: all %d rows failed — rolled back", lines.count)
        } else {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            if errorCount > 0 {
                os_log(.error, log: dictRepoLog, "batchImport: %d/%d rows failed", errorCount, lines.count)
            }
        }
        return errorCount
    }

    /// Returns all cached rows for CSV export.
    func fetchAllForExport() -> [CachedDictEntry] {
        guard let db else { return [] }
        let sql = "SELECT query_word, target_lang, model_name, json_data, updated_at FROM custom_dictionary ORDER BY updated_at DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [CachedDictEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let word  = Self.columnString(stmt, 0)
            let lang  = Self.columnString(stmt, 1)
            let model = Self.columnString(stmt, 2)
            let json  = Self.columnString(stmt, 3)
            let ts    = Self.columnString(stmt, 4)
            rows.append(CachedDictEntry(modelName: model, jsonData: json, timestamp: ts,
                                        word: word, targetLang: lang))
        }
        return rows
    }
}

// MARK: - Data Model

struct CachedDictEntry {
    let modelName: String
    let jsonData: String
    let timestamp: String
    var word: String = ""
    var targetLang: String = ""
}
