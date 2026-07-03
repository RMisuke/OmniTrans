import SwiftUI

// MARK: - Animation gate for settings toggle

/// Cached snapshot of the user's animation preference.
/// Updated when UserDefaults changes to avoid per-frame disk reads.
/// UserDefaults reads are thread-safe, so this is intentionally non-@MainActor.
enum AnimationGate {
    private static var _enabled: Bool = {
        UserDefaults.standard.bool(forKey: "animations_enabled")
    }()

    static var isEnabled: Bool {
        _enabled
    }

    /// Call once on launch and whenever the setting toggle changes.
    static func refresh() {
        _enabled = UserDefaults.standard.bool(forKey: "animations_enabled")
    }
}

extension View {
    /// Disables all implicit and explicit animations when the user has
    /// turned off "动画效果" in Settings → General.
    func animationsGated() -> some View {
        self.transaction { t in
            if !AnimationGate.isEnabled {
                t.disablesAnimations = true
                t.animation = nil
            }
        }
    }
}

/// Safe wrapper around `withAnimation`: no-ops when animations are disabled.
func withAnimationGated<Result>(_ body: () throws -> Result) rethrows -> Result {
    if AnimationGate.isEnabled {
        return try withAnimation(.default, body)
    } else {
        return try body()
    }
}

/// Safe wrapper with explicit animation type.
func withAnimationGated<Result>(_ animation: Animation?, _ body: () throws -> Result) rethrows -> Result {
    if AnimationGate.isEnabled {
        return try withAnimation(animation, body)
    } else {
        return try body()
    }
}
