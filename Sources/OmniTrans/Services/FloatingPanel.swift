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

    /// Current panel size mode from settings.

    /// Map size mode to a concrete height.
    func heightForMode(_ mode: String) -> CGFloat {
        switch mode {
        case "small":   return 320
        case "large":   return 620
        default:        return 460
        }
    }

    /// Elastic bubble pop-in: scale from 0.92 + fade in with spring curve.
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

        alphaValue = 0
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
        TTSManager.shared.stop()
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
