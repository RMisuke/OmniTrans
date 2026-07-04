import Cocoa
import SwiftUI

extension Notification.Name {
    /// Posted by `FloatingPanel.show()` each time the panel is brought on screen.
    static let floatingPanelDidShow = Notification.Name("FloatingPanelDidShow")
}

@MainActor
final class FloatingPanel: NSPanel {
    static let shared = FloatingPanel()

    /// Default panel width — V0.6: expanded from 380 to 420.
    static let defaultWidth: CGFloat = 420

    /// Compressed height for history / minimal content.
    static let minHeight: CGFloat = 280
    /// Expanded height for translation / dictionary content.
    static let maxHeight: CGFloat = 640

    /// When `true`, the panel floats above all windows (`.screenSaver` level)
    /// and ignores click-outside / ESC dismissal.
    var isPinned = false {
        didSet {
            if isPinned {
                level = .screenSaver
            } else {
                // Restore floating level.  Never touch hidesOnDeactivate —
                // setting it to true during a level transition causes AppKit
                // to immediately auto-hide the panel because the level change
                // itself triggers a transient deactivation.
                // Dismiss-on-click-outside is already handled by didResignKey.
                level = .floating
            }
        }
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // ── v0.5 经典 NSPanel 配置 ──
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        // 允许拖拽移动（borderless 窗口必需）
        isMovableByWindowBackground = true
        // 允许接收键盘焦点以执行输入和 Esc 销毁
        becomesKeyOnlyIfNeeded = false

        // 【核心修复】注册失焦通知，当鼠标点击屏幕其他任何地方
        // 或主窗口失焦时，悬浮窗立刻优雅隐退（微秒级响应）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLostFocus),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
        // Track window drag state for ThrottledStream adaptive flush
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillMove), name: NSWindow.willMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidMove), name: NSWindow.didMoveNotification, object: self)
    }

    @objc private func windowWillMove() { AppState.isUserDraggingWindow = true }
    @objc private func windowDidMove()   { AppState.isUserDraggingWindow = false }

    /// 失焦即销毁 —— 不再走 fade-out 动画，直接 `orderOut(nil)`。
    /// Pin 状态下忽略（用户明确希望窗口常驻）。
    @objc private func handleLostFocus() {
        guard !isPinned else { return }
        if UserDefaults.standard.string(forKey: "dismiss_mode") ?? "clickOutside" == "clickOutside" {
            orderOut(nil)
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
        let w = Self.defaultWidth

        if nearMouse, let screen = NSScreen.main {
            let mouse = NSEvent.mouseLocation
            var o = NSPoint(x: mouse.x + 8, y: mouse.y - h - 8)
            let v = screen.visibleFrame
            if o.x + w > v.maxX { o.x = v.maxX - w - 8 }
            if o.y < v.minY { o.y = mouse.y + 24 }
            if o.x < v.minX { o.x = v.minX + 8 }
            setFrame(NSRect(x: o.x, y: o.y, width: w, height: h), display: false)
        } else {
            setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: w, height: h), display: false)
        }

        // Show immediately — no alpha fade, no pre-scale transform
        contentView?.wantsLayer = true
        contentView?.layer?.transform = CATransform3DIdentity
        alphaValue = 1.0
        makeKeyAndOrderFront(nil)
        // Notify SwiftUI views that the panel just appeared so they can
        // reload state even when the hosting view never left the hierarchy.
        NotificationCenter.default.post(name: .floatingPanelDidShow, object: nil)
    }

    /// Dynamically resize the panel height within [minHeight, maxHeight] bounds.
    /// - Parameter targetHeight: Desired content height (clamped).
    /// - Parameter animate: Whether to animate the resize.
    func updateHeight(_ targetHeight: CGFloat, animate: Bool = true) {
        let clamped = max(Self.minHeight, min(Self.maxHeight, targetHeight))
        let w = Self.defaultWidth
        var newFrame = frame
        // Keep bottom edge anchored; grow/shrink upward
        newFrame.origin.y += newFrame.size.height - clamped
        newFrame.size = NSSize(width: w, height: clamped)

        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }

    /// Smooth fade-out, then physically unload SwiftUI view tree to release memory.
    func hide() {
        Task { await TTSManager.shared.stop() }
        MemoryPurgeHelper.shared.purgeBackendCache()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.orderOut(nil) }
        }
    }

    override func close() { hide() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
