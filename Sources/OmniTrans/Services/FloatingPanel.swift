import Cocoa
import SwiftUI

@MainActor
final class FloatingPanel: NSPanel {
    static let shared = FloatingPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(didResignKey), name: NSWindow.didResignKeyNotification, object: self)
    }

    @objc private func didResignKey() {
        if UserDefaults.standard.string(forKey: "dismiss_mode") ?? "clickOutside" == "clickOutside" {
            orderOut(nil)
        }
    }

    func show(nearMouse: Bool = true) {
        if nearMouse, let screen = NSScreen.main {
            let mouse = NSEvent.mouseLocation
            var o = NSPoint(x: mouse.x + 8, y: mouse.y - frame.height - 8)
            let v = screen.visibleFrame
            if o.x + frame.width > v.maxX { o.x = v.maxX - frame.width - 8 }
            if o.y < v.minY { o.y = mouse.y + 24 }
            if o.x < v.minX { o.x = v.minX + 8 }
            setFrameOrigin(o)
        }
        // Elastic pop-in
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
        }
    }
    override func close() { hide() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
