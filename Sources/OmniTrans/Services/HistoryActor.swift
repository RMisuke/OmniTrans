import Foundation

/// Background actor for history persistence with write throttling.
///
/// Instead of calling `UserDefaults.standard.set(...)` synchronously after
/// every translation, `HistoryActor` buffers entries in memory and flushes
/// them in batches to disk after a 5-second idle window.  This eliminates
/// frequent JSON encode + UserDefaults I/O from ever touching the main thread.
actor HistoryActor {
    static let shared = HistoryActor()

    private var pending: [HistoryEntry] = []
    private var flushTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Append a history entry and schedule a deferred flush.
    func add(_ entry: HistoryEntry) {
        pending.insert(entry, at: 0)

        let maxCount = UserDefaults.standard.integer(forKey: "max_history_count")
        let limit = maxCount > 0 ? maxCount : 100
        if pending.count > limit {
            pending = Array(pending.prefix(limit))
        }
        scheduleFlush()
    }

    /// Load cached entries (memory-only).
    func entries() -> [HistoryEntry] { pending }

    /// Load from persistent storage, overwriting in-memory buffer.
    func loadFromDisk() {
        pending = ProviderStorageManager.loadHistory()
    }

    /// Clear all entries from memory and disk.
    func clear() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        ProviderStorageManager.clearHistory()
    }

    /// Force immediate flush (e.g. on app quit).
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        ProviderStorageManager.saveHistory(pending)
    }

    // MARK: - Write throttling

    /// Schedules a 5-second debounced flush.  Each new `add()` call cancels
    /// the previous timer, so rapid successive translations only trigger a
    /// single disk write after the user stops.
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
            guard let self, !Task.isCancelled else { return }
            let snapshot = await self.pending
            ProviderStorageManager.saveHistory(snapshot)
        }
    }
}
