import Cocoa

/// Polls NSPasteboard changeCount and fires translation when new text is copied
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var isRunning = false
    private var lastTranslationTime: Date = .distantPast
    /// Ignore changes originated by our own translate/copy actions
    var suppressNext = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    var isMonitoring: Bool { isRunning }

    private func check() {
        guard !suppressNext else { suppressNext = false; lastChangeCount = NSPasteboard.general.changeCount; return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }

        // Debounce: skip if last translation was less than 2 seconds ago
        let now = Date()
        guard now.timeIntervalSince(lastTranslationTime) > 2.0 else { return }
        lastTranslationTime = now

        DispatchQueue.main.async {
            let s = AppState.shared
            guard !s.isTranslating else { return }
            s.resetForNew(text: text)
            // Show floating panel
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                delegate.showFloatingPanel()
            }
            s.translate()
        }
    }
}
