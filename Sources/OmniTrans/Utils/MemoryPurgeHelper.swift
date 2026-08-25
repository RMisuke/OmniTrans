import AppKit
import Foundation
import OSLog

/// Aggressive memory pressure reducer.
/// - Drains CoreAnimation offscreen caches
/// - Tells malloc to return free pages to the kernel
/// - On system memory warnings, evicts HistoryActor's in-memory cache
///   and forces a UserDefaults flush (≤50 entries).
/// - Called at key lifecycle points (panel hide, OCR completion, app background)
@MainActor
final class MemoryPurgeHelper {
    static let shared = MemoryPurgeHelper()

    /// Whether the system memory pressure monitor has been registered.
    private var warningObserverRegistered = false

    /// DispatchSource for system-level memory pressure events.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// OSLog 句柄 —— 与全工程统一 subsystem（审计 M4）。
    private let memPurgeLog = OSLog(subsystem: AppLogging.subsystem, category: "MemoryPurge")

    private init() {}

    // MARK: - Memory Pressure Registration

    /// Register a `DispatchSource.memoryPressure` monitor that fires on
    /// critical / warning events.  Evicts `HistoryActor`'s in-memory cache
    /// and triggers a full backend purge.
    ///
    /// Should be called once during app launch (e.g. from `AppDelegate`).
    func registerMemoryWarningObserver() {
        guard !warningObserverRegistered else { return }
        warningObserverRegistered = true

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
    }

    // MARK: - Backend Cache Purge

    /// Full purge: off-screen render caches + malloc zone pressure relief.
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
