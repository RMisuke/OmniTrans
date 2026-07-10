import SwiftUI
import AppKit

// MARK: - Easing Curve (CSS cubic-bezier compatible)

/// CSS-compatible cubic-bezier easing curve defined by two control points.
///
/// All presets are designed for 60fps rendering and map directly to
/// `CAMediaTimingFunction` on AppKit for GPU-accelerated compositing.
struct EasingCurve: Sendable, Equatable {
    let c1x: Double
    let c1y: Double
    let c2x: Double
    let c2y: Double

    /// Natural cubic-bezier initializer — reads like CSS `cubic-bezier(c1x, c1y, c2x, c2y)`.
    init(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double) {
        self.c1x = c1x; self.c1y = c1y; self.c2x = c2x; self.c2y = c2y
    }

    // MARK: — Material Design 3 presets —

    static let standard   = EasingCurve(0.25, 0.1, 0.25, 1.0)
    static let decelerate = EasingCurve(0.0, 0.0, 0.2, 1.0)
    static let accelerate = EasingCurve(0.4, 0.0, 1.0, 1.0)
    static let sharp      = EasingCurve(0.4, 0.0, 0.6, 1.0)
    static let linear     = EasingCurve(0.0, 0.0, 1.0, 1.0)

    // MARK: — Apple HIG presets —

    static let easeInOut  = standard
    static let easeOut    = EasingCurve(0.0, 0.0, 0.25, 1.0)
    static let easeIn     = EasingCurve(0.42, 0.0, 1.0, 1.0)

    // MARK: - Conversion

    var mediaTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(c1x), Float(c1y), Float(c2x), Float(c2y))
    }
}

// MARK: - Spring Model (physics-based)

struct SpringModel: Sendable, Equatable {
    let mass: Double
    let stiffness: Double
    let damping: Double
    let initialVelocity: Double

    init(mass: Double = 1.0, stiffness: Double = 170, damping: Double = 15, initialVelocity: Double = 0) {
        self.mass = mass; self.stiffness = stiffness
        self.damping = damping; self.initialVelocity = initialVelocity
    }

    // MARK: — Presets —

    static let snappy = SpringModel(mass: 1.0, stiffness: 300, damping: 20)
    static let smooth = SpringModel(mass: 1.0, stiffness: 170, damping: 17)
    static let bouncy = SpringModel(mass: 1.0, stiffness: 120, damping: 10)
    static let gentle = SpringModel(mass: 1.0, stiffness: 200, damping: 25)

    /// **refined** — 精致优雅弹簧，极轻微回弹，适合面板入场与内容过渡。
    ///
    /// 阻尼比 ≈ 0.90，接近临界阻尼，反弹几乎不可感知。
    static let refined = SpringModel(mass: 1.0, stiffness: 150, damping: 22)

    func toSwiftUIAnimation(duration: Double) -> Animation {
        .interpolatingSpring(mass: mass, stiffness: stiffness,
                             damping: damping, initialVelocity: initialVelocity)
    }
}

// MARK: - Duration Scale

enum DurationScale: Double, Sendable, CaseIterable {
    case fast   = 0.7
    case normal = 1.0
    case slow   = 1.5

    var displayName: String {
        switch self {
        case .fast: "快速"; case .normal: "标准"; case .slow: "慢速"
        }
    }
}

// MARK: - Animation Token Box (indirection for recursive Self)

private final class AnimationTokenBox: @unchecked Sendable {
    let value: AnimationToken?
    init(_ value: AnimationToken?) { self.value = value }
}

// MARK: - Animation Token

struct AnimationToken: Sendable {
    let name: String
    let easing: EasingCurve
    let duration: Double
    let spring: SpringModel?
    let scale: DurationScale
    private let _fallbackBox: AnimationTokenBox?

    var accessibilityFallback: AnimationToken? { _fallbackBox?.value }

    init(name: String,
         easing: EasingCurve = .standard,
         duration: Double,
         spring: SpringModel? = nil,
         scale: DurationScale = .normal,
         accessibilityFallback: AnimationToken? = nil) {
        self.name = name; self.easing = easing; self.duration = duration
        self.spring = spring; self.scale = scale
        self._fallbackBox = accessibilityFallback.map(AnimationTokenBox.init)
    }

    var effectiveDuration: Double { duration * scale.rawValue }

    /// Resolve to a SwiftUI `Animation`, respecting reduce-motion:
    /// - If reduce-motion is ON → returns `fallback` if available, else `.linear(duration: 0)`.
    /// - Otherwise uses spring (if set) or cubic-bezier timing curve.
    func resolve() -> Animation {
        if AnimationEngine.isReducedMotion {
            if let fallback = accessibilityFallback { return fallback.resolve() }
            return .linear(duration: 0)
        }
        let d = effectiveDuration
        if let s = spring {
            return s.toSwiftUIAnimation(duration: d)
        }
        return .timingCurve(easing.c1x, easing.c1y, easing.c2x, easing.c2y, duration: d)
    }

    /// Resolve gated: respects BOTH `AnimationGate.isEnabled` AND reduce-motion.
    /// Returns `nil` when animations are disabled — SwiftUI falls back to instant.
    func resolveGated() -> Animation? {
        AnimationGate.isEnabled ? resolve() : nil
    }

    /// Build an `AnyTransition` from this token (opacity + optional offset).
    /// Automatically respects gate and reduce-motion.
    func asTransition(offset: CGFloat = 8) -> AnyTransition {
        .opacity.combined(with: .offset(y: offset))
            .animation(resolveGated())
    }

    /// Build an asymmetric transition (insert uses self, removal uses removalToken).
    func asAsymmetricTransition(removal removalToken: AnimationToken, insertionOffset: CGFloat = 8, removalOffset: CGFloat = -8) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: insertionOffset))
                .animation(resolveGated()),
            removal: .opacity.combined(with: .offset(y: removalOffset))
                .animation(removalToken.resolveGated())
        )
    }
}

extension AnimationToken: Equatable {
    static func == (lhs: AnimationToken, rhs: AnimationToken) -> Bool {
        lhs.name == rhs.name && lhs.easing == rhs.easing
        && lhs.duration == rhs.duration && lhs.spring == rhs.spring
        && lhs.scale == rhs.scale && lhs.accessibilityFallback == rhs.accessibilityFallback
    }
}

// MARK: - Animation Engine

enum AnimationEngine {
    nonisolated(unsafe) static var durationScale: DurationScale = .normal

    static var isReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Resolution

    static func resolve(_ token: AnimationToken) -> Animation {
        token.resolve()  // reduceMotion check is now inside resolve()
    }

    static func resolveGated(_ token: AnimationToken) -> Animation? {
        guard AnimationGate.isEnabled else { return nil }
        return resolve(token)
    }

    /// AppKit animation bridge. Must be called from the main actor.
    @MainActor
    static func animateAppKit(_ token: AnimationToken, block: @escaping () -> Void) {
        let effectiveDuration = token.effectiveDuration
        if token.spring != nil {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = effectiveDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                block()
            }
        } else if isReducedMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                block()
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = effectiveDuration
                ctx.timingFunction = token.easing.mediaTimingFunction
                ctx.allowsImplicitAnimation = true
                block()
            }
        }
    }

    static func disableActions(_ block: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block()
        CATransaction.commit()
    }
}

// MARK: - Instant Token

extension AnimationToken {
    static let instant = AnimationToken(name: "instant", easing: .linear, duration: 0,
                                        spring: nil, scale: .normal, accessibilityFallback: nil)

    /// AppKit NSAnimationContext 可直接使用的持续时长（含 DurationScale）。
    var appKitDuration: TimeInterval { effectiveDuration }
}

// MARK: - SwiftUI Integration

extension Animation {
    static func token(_ token: AnimationToken) -> Animation {
        AnimationEngine.resolve(token)
    }

    static func tokenGated(_ token: AnimationToken) -> Animation? {
        AnimationEngine.resolveGated(token)
    }

}

extension View {
    func animation<V: Equatable>(_ token: AnimationToken, value: V) -> some View {
        self.animation(AnimationEngine.resolveGated(token), value: value)
    }
}

// MARK: - Frame Tracker

actor FrameTracker {
    static let shared = FrameTracker()

    private var frameDurations: [CFTimeInterval] = []
    private let maxSamples = 60

    var currentFPS: Int {
        guard !frameDurations.isEmpty else { return 60 }
        let avg = frameDurations.reduce(0, +) / Double(frameDurations.count)
        guard avg > 0 else { return 60 }
        return Int(1.0 / avg)
    }

    var isThrottling: Bool { currentFPS < 45 }

    func reportFrame(duration: CFTimeInterval) {
        frameDurations.append(duration)
        if frameDurations.count > maxSamples {
            frameDurations.removeFirst(frameDurations.count - maxSamples)
        }
    }

    func adaptiveScale() -> DurationScale {
        isThrottling ? .fast : AnimationEngine.durationScale
    }
}

// MARK: - Stagger Engine

struct StaggerConfig: Sendable {
    let count: Int
    let baseDelay: Double

    var totalDuration: Double { Double(count) * baseDelay }

    func delay(for index: Int) -> Double { Double(index) * baseDelay }

    func animation(for index: Int, token: AnimationToken) -> Animation {
        token.resolve().delay(delay(for: index))
    }

    func animationGated(for index: Int, token: AnimationToken) -> Animation? {
        guard AnimationGate.isEnabled else { return nil }
        return token.resolve().delay(delay(for: index))
    }
}
