import AppKit
import Foundation
import OSLog

/// Aggressive memory pressure reducer.
/// - Drains CoreAnimation offscreen caches
/// - Tells malloc to return free pages to the kernel
/// - On system memory warnings, evicts HistoryActor's in-memory cache
///   and forces a UserDefaults flush (≤50 entries).
/// - On OCR idle (30s after completion): deferred gentle reclaim — balances
///   keeping Vision buffers warm during rapid OCR vs reclaiming when idle.
/// - On new OCR start: cancels pending deferred purge to preserve buffers.
@MainActor
final class MemoryPurgeHelper {
    static let shared = MemoryPurgeHelper()

    /// Whether the system memory pressure monitor has been registered.
    private var warningObserverRegistered = false

    /// DispatchSource for system-level memory pressure events.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// OCR idle deferred purge timer — fires 30s after last OCR completes.
    /// Cancelled immediately on new OCR start, so Vision buffers stay warm
    /// during rapid sequential recognitions.
    private var idlePurgeWorkItem: DispatchWorkItem?

    /// OCR idle delay before deferred purge.  Long enough to skip purge
    /// between rapid sequential OCRs, short enough to reclaim promptly
    /// when the user actually stops.
    private static let idlePurgeDelay: TimeInterval = 30.0

    /// OSLog 句柄 —— 与全工程统一 subsystem（审计 M4）。
    private let memPurgeLog = OSLog(subsystem: AppLogging.subsystem, category: "MemoryPurge")

    private init() {}

    // MARK: - Memory Pressure Registration

    /// Register a `DispatchSource.memoryPressure` monitor that fires on
    /// critical / warning events.  Evicts `HistoryActor`'s in-memory cache
    /// and triggers a full backend purge.
    ///
    /// Also registers OCR idle/start observers for deferred reclaim.
    /// Should be called once during app launch (e.g. from `AppDelegate`).
    func registerMemoryWarningObserver() {
        guard !warningObserverRegistered else { return }
        warningObserverRegistered = true

        // ── System memory pressure ──
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event == .warning || event == .critical {
                os_log(.error, log: memPurgeLog, "System memory pressure (%{public}@) — evicting caches", "\(event)")
                Task { await HistoryActor.shared.evictMemoryCache() }
                self.purgeBackendCache()
            }
        }
        source.resume()
        memoryPressureSource = source

        // ── OCR idle deferred purge ──
        // 新一轮 OCR 开始 → 取消待执行的延迟清理（保留 Vision 缓冲）。
        NotificationCenter.default.addObserver(
            forName: .omniTransOCRLoading, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelIdlePurge() }
        }
        // OCR 完成/失败 → 调度延迟清理。
        NotificationCenter.default.addObserver(
            forName: .omniTransOCRDone, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIdlePurge() }
        }
    }

    // MARK: - OCR Idle Deferred Purge

    /// Schedule a deferred purge after `idlePurgeDelay` seconds.
    /// If already scheduled, this is a no-op (coalesces rapid OCR completions).
    private func scheduleIdlePurge() {
        guard idlePurgeWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.idlePurgeWorkItem = nil
            os_log(.info, log: self.memPurgeLog,
                   "OCR idle %.0fs — deferred backend purge", Self.idlePurgeDelay)
            self.purgeBackendCache()
        }
        idlePurgeWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.idlePurgeDelay, execute: item)
    }

    /// Cancel any pending deferred purge (called on new OCR start).
    private func cancelIdlePurge() {
        guard let item = idlePurgeWorkItem else { return }
        item.cancel()
        idlePurgeWorkItem = nil
    }

    // MARK: - Backend Cache Purge

    /// Full purge: off-screen render caches + malloc zone pressure relief.
    ///
    /// Call sites:
    /// - System memory pressure events (critical / warning)
    /// - OCR idle deferred purge (5s after last OCR completes)
    ///
    /// Deliberately **not** called on every OCR completion or panel hide —
    /// doing so destroys Vision internal buffers (~60MB) that cost ~1-2s
    /// to rebuild, causing consecutive OCR recognitions to regress to cold
    /// start latency.
    func purgeBackendCache() {
        // 1. Flush CoreAnimation's offscreen render caches
        CATransaction.flush()

        // 2. Touch CoreGraphics to flush its internal caches
        _ = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)

        // 3. Mach-level: query TASK_VM_INFO — 读取 phys_footprint 作为
        //    purge 前的内存基线（B14：真正使用返回值，不再丢弃）
        #if arch(arm64) || arch(x86_64)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let footprintMB = Double(info.phys_footprint) / (1024.0 * 1024.0)
            os_log(.debug, log: memPurgeLog, "purge: phys_footprint=%.1f MB", footprintMB)
        }
        #endif

        // 4. malloc zone pressure relief — tell system allocator to return
        //    free pages to the kernel immediately (key for OCR memory recovery)
        malloc_zone_pressure_relief(nil, 0)
    }
}
