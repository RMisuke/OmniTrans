import Foundation
import os.log

/// Background actor for history persistence with streaming JSONL writes.
///
/// ## Architecture
/// - **UserDefaults** retains a maximum of `maxUserDefaultsEntries` entries for instant UI
///   first-frame rendering (lightweight, no disk seek on launch).
/// - **Sandbox JSONL** (`history_archive.jsonl`) stores the complete history
///   as a line-delimited JSON stream.  Each new entry is appended via
///   `FileHandle.seekToEndOfFile`, avoiding full-file rewrites.
/// - **Memory pressure**: On system memory warnings, cached entries are
///   released and a "dirty" flag is set; subsequent UI requests trigger a
///   streaming read from the JSONL file.
/// - **Chunked read**: `loadFromArchive` uses `FileHandle.read(upToCount:)` in
///   64KB chunks to avoid loading the entire JSONL file into memory at once.
/// - **maxHistoryCount**: The cap on archived entries is read from UserDefaults
///   (`max_history_count`), defaulting to 100.  Entries beyond this count are
///   trimmed from the JSONL archive on each `flushNow()` cycle.
///
/// The 5-second debounced flush from the previous implementation is preserved
/// for UserDefaults, while JSONL writes happen immediately (streaming append
/// is O(1) I/O).
actor HistoryActor {
    static let shared = HistoryActor()

    /// Logger for persistence errors — uses the app's subsystem.
    private static let log = OSLog(subsystem: "com.omnitrans.app", category: "HistoryActor")

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

    /// Chunk size for streaming JSONL reads (64 KB).
    private static let readChunkSize = 65_536

    /// JSON encoder reused across writes — no allocation per entry.
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private init() {}

    // MARK: - Configuration

    /// Reads `max_history_count` from UserDefaults.  Defaults to 100 if unset.
    private nonisolated var maxHistoryCount: Int {
        let count = UserDefaults.standard.integer(forKey: "max_history_count")
        return count > 0 ? count : 100
    }

    // MARK: - JSONL Archive Path

    private func archiveURL() -> URL {
        StoragePaths.historyArchive
    }

    private func openArchive() -> FileHandle? {
        if let h = archiveHandle { return h }
        let url = archiveURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            os_log(.error, log: Self.log, "HistoryActor: failed to open archive for writing at %{public}@", url.path)
            return nil
        }
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
            os_log(.info, log: Self.log, "HistoryActor: in-memory buffer capped at 2000 entries")
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
    /// Respects `maxHistoryCount` to cap the number of entries loaded.
    func loadFromDisk() {
        let cap = maxHistoryCount
        let archived = loadFromArchive(limit: cap)
        if !archived.isEmpty {
            pending = archived
            let trimmed = Array(archived.prefix(Self.maxUserDefaultsEntries))
            ProviderStorageManager.saveHistory(trimmed)
        } else {
            pending = ProviderStorageManager.loadHistory()
        }
    }

    /// Clear all entries from memory, UserDefaults, and JSONL archive.
    func clear() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        ProviderStorageManager.clearHistory()
        let url = archiveURL()
        do {
            try Data().write(to: url)
        } catch {
            os_log(.error, log: Self.log, "HistoryActor: failed to truncate archive: %{public}@", error.localizedDescription)
        }
        closeArchive()
    }

    /// Force immediate flush (e.g. on app quit).
    /// Trims the JSONL archive to `maxHistoryCount` entries to prevent unbounded growth.
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else {
            closeArchive()
            return
        }

        // Trim to maxHistoryCount and persist the capped set
        let cap = maxHistoryCount
        let trimmed = Array(pending.prefix(Self.maxUserDefaultsEntries))
        ProviderStorageManager.saveHistory(trimmed)

        // Truncate & rewrite JSONL archive to only the capped entries
        rewriteArchive(cappedTo: cap)
        closeArchive()
    }

    /// Called when the user changes `maxHistoryCount` in Settings.
    /// Deduplicates adjacent entries, trims to `limit`, rewrites the
    /// JSONL archive, and updates the in-memory buffer.
    func applyLimitAndDedup(limit: Int) {
        flushTask?.cancel()
        flushTask = nil

        // Dedup adjacent duplicates (newest-first), then trim to limit
        let deduped = deduplicateAdjacent(pending)
        pending = Array(deduped.prefix(limit))

        // Sync trimmed set to UserDefaults for fast UI launch
        let trimmed = Array(pending.prefix(Self.maxUserDefaultsEntries))
        ProviderStorageManager.saveHistory(trimmed)

        // Rewrite archive with deduped + capped entries
        rewriteArchive(cappedTo: limit)
        closeArchive()
        isDirty = false
    }

    /// Release in-memory cache on memory pressure; mark as dirty for
    /// on-demand reload from JSONL archive.
    func evictMemoryCache() {
        flushTask?.cancel()
        flushTask = nil
        // Flush current state before evicting
        let trimmed = Array(pending.prefix(Self.maxUserDefaultsEntries))
        ProviderStorageManager.saveHistory(trimmed)
        let cap = maxHistoryCount
        rewriteArchive(cappedTo: cap)
        closeArchive()
        pending.removeAll()
        isDirty = true
    }

    // MARK: - JSONL Streaming Write

    private func writeEntryToArchive(_ entry: HistoryEntry) {
        guard let handle = openArchive() else { return }
        guard let jsonData = try? jsonEncoder.encode(entry) else {
            os_log(.error, log: Self.log, "HistoryActor: failed to encode entry (id=%{public}@)", entry.id.uuidString)
            return
        }
        var line = jsonData
        line.append(0x0A)  // newline delimiter
        do {
            try handle.write(contentsOf: line)
        } catch {
            os_log(.error, log: Self.log, "HistoryActor: JSONL write failed: %{public}@", error.localizedDescription)
            // Close the handle so next write retries with a fresh one
            closeArchive()
        }
    }

    // MARK: - JSONL Rewrite (trimming)

    /// Rewrites the JSONL archive with only the newest `cap` entries.
    /// Used by `flushNow()` and `evictMemoryCache()` to enforce `maxHistoryCount`.
    /// Entries are deduplicated (adjacent same-provider+output) before writing.
    private func rewriteArchive(cappedTo cap: Int) {
        let url = archiveURL()
        closeArchive()

        // Read all entries (already deduped by loadFromArchive), then cap
        let allEntries = loadFromArchive()
        let capped = Array(allEntries.prefix(cap))

        do {
            var data = Data()
            var encodeFailures = 0
            for entry in capped.reversed() {  // write oldest-first for streaming append
                if let jsonData = try? jsonEncoder.encode(entry) {
                    data.append(jsonData)
                    data.append(0x0A)
                } else {
                    encodeFailures += 1
                }
            }
            try data.write(to: url)
            if encodeFailures > 0 {
                os_log(.error, log: Self.log, "HistoryActor: %d entries failed to encode during archive rewrite", encodeFailures)
            }
        } catch {
            os_log(.error, log: Self.log, "HistoryActor: archive rewrite failed: %{public}@", error.localizedDescription)
        }
    }

    // MARK: - Dedup Helpers

    /// Removes adjacent duplicates (same providerName + output),
    /// keeping only the newest of each consecutive group.
    /// Array must be in newest-first order.
    private func deduplicateAdjacent(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        guard entries.count > 1 else { return entries }
        var result: [HistoryEntry] = [entries[0]]
        for i in 1..<entries.count {
            let prev = result[result.count - 1]
            let curr = entries[i]
            if curr.output == prev.output && curr.providerName == prev.providerName {
                continue  // skip older duplicate
            }
            result.append(curr)
        }
        return result
    }

    // MARK: - JSONL Streaming Read (chunked)

    /// Reads entries from the JSONL archive using chunked I/O to avoid
    /// loading the entire file into memory at once.
    /// Returns newest-first (reverse line order).
    private func loadFromArchive(limit: Int = Int.max) -> [HistoryEntry] {
        let url = archiveURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            os_log(.error, log: Self.log, "HistoryActor: cannot open archive for reading")
            return []
        }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        var entries: [HistoryEntry] = []
        var leftover = Data()  // partial line carried between chunks

        while true {
            let chunk = (try? handle.read(upToCount: Self.readChunkSize)) ?? Data()
            if chunk.isEmpty { break }  // EOF

            var buffer = leftover + chunk

            // Process complete lines within this chunk
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer = buffer[(newlineIndex + 1)...]

                if !lineData.isEmpty {
                    if let entry = try? decoder.decode(HistoryEntry.self, from: Data(lineData)) {
                        entries.append(entry)
                    }
                    // Silently skip corrupted lines (json decode failure)
                }
            }
            leftover = buffer
        }

        // Process final line (no trailing newline)
        if !leftover.isEmpty {
            if let entry = try? decoder.decode(HistoryEntry.self, from: Data(leftover)) {
                entries.append(entry)
            }
        }

        // Return newest-first, deduplicated and limited
        let reversed = entries.reversed()
        let deduped = deduplicateAdjacent(Array(reversed))
        let capped = deduped.prefix(limit)
        return Array(capped)
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
