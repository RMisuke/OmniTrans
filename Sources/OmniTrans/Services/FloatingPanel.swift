import Cocoa
import SwiftUI

@MainActor
final class FloatingPanel: NSPanel {
    static let shared = FloatingPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(didResignKey), name: NSWindow.didResignKeyNotification, object: self)
        // Track window drag state for ThrottledStream adaptive flush
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillMove), name: NSWindow.willMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidMove), name: NSWindow.didMoveNotification, object: self)
    }

    @objc private func windowWillMove() { AppState.isUserDraggingWindow = true }
    @objc private func windowDidMove()   { AppState.isUserDraggingWindow = false }

    @objc private func didResignKey() {
        if UserDefaults.standard.string(forKey: "dismiss_mode") ?? "clickOutside" == "clickOutside" {
            hide()
        }
    }

    /// Map size mode to a concrete height.
    func heightForMode(_ mode: String) -> CGFloat {
        switch mode {
        case "small":   return 320
        case "large":   return 620
        default:        return 460
        }
    }

    /// Show the floating panel near the mouse cursor.
    ///
    /// **Instant-first strategy**: `makeKeyAndOrderFront` is called immediately
    /// with full opacity and identity transform so the window appears with zero
    /// perceived latency.  A lightweight spring scale animation runs
    /// asynchronously on the Core Animation render server — it never blocks
    /// the main thread and does not delay the first paint.
    func show(nearMouse: Bool = true) {
        let h = heightForMode(UserDefaults.standard.string(forKey: "panel_size") ?? "default")

        if nearMouse, let screen = NSScreen.main {
            let mouse = NSEvent.mouseLocation
            var o = NSPoint(x: mouse.x + 8, y: mouse.y - h - 8)
            let v = screen.visibleFrame
            if o.x + 380 > v.maxX { o.x = v.maxX - 380 - 8 }
            if o.y < v.minY { o.y = mouse.y + 24 }
            if o.x < v.minX { o.x = v.minX + 8 }
            setFrame(NSRect(x: o.x, y: o.y, width: 380, height: h), display: false)
        } else {
            setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: 380, height: h), display: false)
        }

        // Show immediately — no alpha fade, no pre-scale transform
        contentView?.wantsLayer = true
        contentView?.layer?.transform = CATransform3DIdentity
        alphaValue = 1.0
        makeKeyAndOrderFront(nil)
    }

    /// Smooth fade-out, then physically unload SwiftUI view tree to release memory.
    func hide() {
        Task { await TTSManager.shared.stop() }
        MemoryPurgeHelper.shared.purgeBackendCache()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
        }
    }

    override func close() { hide() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
