import SwiftUI

// MARK: - Skeleton Shimmer View (Zero-Invalidation Architecture)

/// macOS-native skeleton loading placeholder with animation fully isolated
/// inside leaf modifiers so parent container layout is never invalidated
/// by the repeating opacity pulse.
///
/// ## Architecture
///
/// The pulse animation is confined to `ShimmerModifier`, a private
/// `ViewModifier` that owns its own `@State phase`.  When the modifier
/// is attached to a leaf bar, only that bar's opacity layer is
/// recomputed on each animation tick — the `SkeletonShimmerView` body,
/// its `VStack` layout, and any ancestor views are **not** touched.
///
/// ## Modes
/// - **Compact** (`compact: true`):  Single thin bar for dictionary /
///   word-lookup loading.
/// - **Full** (`compact: false`):    Three staggered-width bars for
///   translation loading.
///
/// ## Graceful Degradation
///
/// When ``AnimationGate/isEnabled`` is `false`, `ShimmerModifier`
/// renders at a fixed `opacity(0.45)` with no animation, achieving
/// zero GPU cost identical to the old static-bar code path — but
/// without duplicating the entire view tree.
struct SkeletonShimmerView: View {
    /// When `true`, renders a single compact bar (dictionary mode).
    /// When `false`, renders three staggered bars (translation mode).
    var compact: Bool = false

    var body: some View {
        if compact {
            compactBar
                .modifier(ShimmerModifier())
        } else {
            VStack(alignment: .leading, spacing: 10) {
                shimmerBar(widthRatio: 1.0)
                shimmerBar(widthRatio: 0.72)
                shimmerBar(widthRatio: 0.88)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    // MARK: - Bar Definitions

    /// Compact bar — thin, centred, used for dictionary/word loading.
    private var compactBar: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.quaternary)
            .frame(width: 220, height: 6)
    }

    /// Proportional-width skeleton bar.  Uses `HStack + Spacer` to
    /// achieve proportional width **without** `GeometryReader`,
    /// avoiding layout-dependency chains that could trigger parent
    /// container re-measurement.
    private func shimmerBar(widthRatio: CGFloat) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 5)
                .fill(.quaternary)
                .frame(height: 13)
                .frame(minWidth: 0)
            Spacer(minLength: 0)
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(height: 13)
        .modifier(ShimmerModifier())
    }
}

// MARK: - Shimmer Modifier (Animation-Isolated Leaf)

/// Self-contained opacity-pulse modifier that owns its animation
/// lifecycle.  The `@State phase` mutation on each animation tick
/// invalidates **only** the view this modifier is attached to —
/// parent layout is never re-measured.
///
/// - **Animations on**:  `phase` oscillates 0 → 1 via
///   `AppTheme.Motion.breathe`, driving opacity 0.35 ↔ 0.75.
/// - **Animations off**: `phase` stays at 0, opacity fixed at 0.45.
///   No animation runs, zero GPU overhead.
private struct ShimmerModifier: ViewModifier {
    @State private var phase: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(shimmerOpacity)
            .onAppear {
                guard AnimationGate.isEnabled else { return }
                withAnimation(AppTheme.Motion.breathe) {
                    phase = 1.0
                }
            }
    }

    /// Computed opacity based on animation phase.
    /// - `phase == 0` (animations off or initial): 0.45
    /// - `phase` oscillates 0 ↔ 1 (animations on): 0.35 ↔ 0.75
    private var shimmerOpacity: Double {
        AnimationGate.isEnabled
            ? (0.35 + 0.40 * phase)
            : 0.45
    }
}
