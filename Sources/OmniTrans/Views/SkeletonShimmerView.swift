import SwiftUI

/// macOS-native skeleton loading placeholder.
///
/// Uses subtle opacity-pulsing rounded rectangles that mimic the system's
/// built-in loading indicators (Finder, Settings, Mail).  No sliding gradients
/// — just a clean, calm breathing effect that blends naturally into the glass
/// background.
///
/// - **Compact mode**: single bar for dictionary / word lookup.
/// - **Full mode**:    three staggered bars for translation loading.
struct SkeletonShimmerView: View {
    var compact: Bool = false

    @AppStorage("animations_enabled") private var animationsEnabled = true
    @State private var opacity: Double = 0.35

    private var pulse: Animation? {
        animationsEnabled
            ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
            : nil
    }

    var body: some View {
        if compact {
            compactBar
                .opacity(opacity)
                .onAppear { if animationsEnabled { withAnimation(pulse) { opacity = 0.7 } } }
                .animation(pulse, value: opacity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                skeletonBar(widthRatio: 1.0, delay: 0.0)
                skeletonBar(widthRatio: 0.72, delay: 0.15)
                skeletonBar(widthRatio: 0.88, delay: 0.30)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    // MARK: - Compact single bar

    private var compactBar: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.quaternary)
            .frame(width: 220, height: 6)
    }

    // MARK: - Staggered bars (full mode)

    private func skeletonBar(widthRatio: CGFloat, delay: Double) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 5)
                .fill(.quaternary)
                .frame(width: geo.size.width * widthRatio, height: 13)
                .modifier(StaggeredPulseModifier(animationsEnabled: animationsEnabled, delay: delay))
        }
        .frame(height: 13)
    }
}

// MARK: - Staggered pulse modifier

/// Applies an opacity-pulse animation with a configurable start delay,
/// creating a staggered wave effect across multiple skeleton bars.
private struct StaggeredPulseModifier: ViewModifier {
    let animationsEnabled: Bool
    let delay: Double

    @State private var opacity: Double = 0.25

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onAppear {
                guard animationsEnabled else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        opacity = 0.6
                    }
                }
            }
            .onDisappear { opacity = 0.25 }
    }
}
