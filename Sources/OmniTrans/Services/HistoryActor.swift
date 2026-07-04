import Foundation

/// Background actor for history persistence with streaming JSONL writes.
///
/// ## Architecture
/// - **UserDefaults** retains a maximum of **50** entries for instant UI
///   first-frame rendering (lightweight, no disk seek on launch).
/// - **Sandbox JSONL** (`history_archive.jsonl`) stores the complete history
///   as a line-delimited JSON stream.  Each new entry is appended via
///   `FileHandle.seekToEndOfFile`, avoiding full-file rewrites.
/// - **Memory pressure**: On `didReceiveMemoryWarning`, cached entries are
///   released and a "dirty" flag is set; subsequent UI requests trigger a
///   streaming read from the JSONL file.
///
/// The 5-second debounced flush from the previous implementation is preserved
/// for UserDefaults, while JSONL writes happen immediately (streaming append
/// is O(1) I/O).
actor HistoryActor {
    static let shared = HistoryActor()

    /// In-memory buffer — mirrored to UserDefaults (≤50) and JSONL (unbounded).
    private var pending: [HistoryEntry] = []

    /// Task for debounced UserDefaults flush.
    private var flushTask: Task<Void, Never>?

    /// FileHandle for streaming JSONL writes.
    private var archiveHandle: FileHandle?

    /// Whether the in-memory cache has been evicted (memory pressure).
    private var isDirty = false

    /// Maximum entries kept in UserDefaults for fast UI launch.
    private static let maxUserDefaultsEntries = 50

    /// JSON encoder reused across writes — no allocation per entry.
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private init() {}

    // MARK: - JSONL Archive Path

    private func archiveURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history_archive.jsonl")
    }

    private func openArchive() -> FileHandle? {
        if let h = archiveHandle { return h }
        let url = archiveURL()
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        archiveHandle = h
        return h
    }

    private func closeArchive() {
        try? archiveHandle?.synchronize()
        try? archiveHandle?.close()
        archiveHandle = nil
    }

    // MARK: - Public API

    /// Append a history entry: insert into memory, trim UserDefaults,
    /// write to JSONL immediately, schedule debounced UserDefaults flush.
    func add(_ entry: HistoryEntry) {
        pending.insert(entry, at: 0)

        // Cap in-memory to a reasonable bound (full archive lives on disk)
        if pending.count > 2000 {
            pending = Array(pending.prefix(2000))
        }

        // ── Immediate JSONL append ──
        writeEntryToArchive(entry)

        // ── Debounced UserDefaults flush (≤50 entries) ──
        scheduleFlush()
    }

    /// Load cached entries (memory-only).  If the cache was purged by memory
    /// pressure, triggers a streaming reload from JSONL.
    func entries() -> [HistoryEntry] {
        if isDirty {
            pending = loadFromArchive(limit: 200)
            isDirty = false
        }
        return pending
    }

    /// Load from persistent storage, overwriting in-memory buffer.
    func loadFromDisk() {
        // Try JSONL archive first (complete history)
        let archived = loadFromArchive()
        if !archived.isEmpty {
            pending = archived
            // Sync trimmed set to UserDefaults for fast launch
            let trimmed = Array(archived.prefix(Self.maxUserDefaultsEntries))
            ProviderStorageManager.saveHistory(trimmed)
        } else {
            // Fallback: load from UserDefaults legacy storage
            pending = ProviderStorageManager.loadHistory()
        }
    }

    /// Clear all entries from memory, UserDefaults, and JSONL archive.
    func clear() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        ProviderStorageManager.clearHistory()
        // Truncate JSONL archive
        let url = archiveURL()
        try? Data().write(to: url)  // empty file
        closeArchive()
    }

    /// Force immediate flush (e.g. on app quit).
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let trimmed = Array(pending.prefix(Self.maxUserDefaultsEntries))
        ProviderStorageManager.saveHistory(trimmed)
        closeArchive()
    }

    /// Release in-memory cache on memory pressure; mark as dirty for
    /// on-demand reload from JSONL archive.
    func evictMemoryCache() {
        flushNow()
        pending.removeAll()
        isDirty = true
        closeArchive()
    }

    // MARK: - JSONL Streaming Write

    private func writeEntryToArchive(_ entry: HistoryEntry) {
        guard let handle = openArchive() else { return }
        guard let jsonData = try? jsonEncoder.encode(entry) else { return }
        var line = jsonData
        line.append(0x0A)  // newline delimiter
        try? handle.write(contentsOf: line)
    }

    // MARK: - JSONL Streaming Read

    /// Reads entries from the JSONL archive.  Uses `FileHandle.readToEnd`
    /// for small archives; for very large files, a chunked reader could
    /// be substituted.  Returns newest-first (reverse line order).
    private func loadFromArchive(limit: Int = Int.max) -> [HistoryEntry] {
        let url = archiveURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }

        let decoder = JSONDecoder()
        var entries: [HistoryEntry] = []

        // Split by newline and parse each line
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard entries.count < limit else { break }
            if let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) {
                entries.append(entry)
            }
        }
        return entries
    }

    // MARK: - Write Throttling (UserDefaults)

    /// Schedules a 5-second debounced flush to UserDefaults (≤50 entries).
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
            guard let self, !Task.isCancelled else { return }
            let snapshot = await self.pending
            let trimmed = Array(snapshot.prefix(Self.maxUserDefaultsEntries))
            ProviderStorageManager.saveHistory(trimmed)
        }
    }
}
