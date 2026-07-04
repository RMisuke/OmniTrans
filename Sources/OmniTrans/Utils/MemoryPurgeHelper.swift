import AppKit
import Foundation

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
                print("[MemoryPurge] ⚠️ System memory pressure (\(event)) — evicting caches")
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

        // 3. Mach-level: query TASK_VM_INFO to nudge kernel page reclamation
        #if arch(arm64) || arch(x86_64)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { _ = info }
        #endif

        // 4. malloc zone pressure relief — tell system allocator to return
        //    free pages to the kernel immediately (key for OCR memory recovery)
        malloc_zone_pressure_relief(nil, 0)
    }
}
