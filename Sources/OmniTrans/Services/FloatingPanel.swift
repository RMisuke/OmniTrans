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
            hide()
        }
    }

    /// Elastic bubble pop-in: scale from 0.92 + fade in with spring curve.
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

        alphaValue = 0
        // Ensure content view is layer-backed for scale animation
        contentView?.wantsLayer = true
        if let cv = contentView {
            cv.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        }

        makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            animator().alphaValue = 1
        }

        // Spring-based scale restitution via layer keyframe
        if let cv = contentView {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.92
            spring.toValue = 1.0
            spring.mass = 1.2
            spring.stiffness = 280
            spring.damping = 20
            spring.initialVelocity = 0.5
            spring.duration = spring.settlingDuration
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
            cv.layer?.add(spring, forKey: "popIn")
        }
    }

    /// Smooth fade-out, then order out.
    func hide() {
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
