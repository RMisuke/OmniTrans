import SwiftUI

/// Skeleton loading placeholder with shimmer animation.
/// Used during MT translation waits (200–600ms single-shot requests).
struct SkeletonShimmerView: View {
    @State private var phase: CGFloat = -1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            shimmerLine(widthRatio: 1.0)
            shimmerLine(widthRatio: 0.72)
            shimmerLine(widthRatio: 0.88)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }

    private func shimmerLine(widthRatio: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.primary.opacity(0.08),
                            Color.primary.opacity(0.18),
                            Color.primary.opacity(0.08)
                        ]),
                        startPoint: UnitPoint(x: phase - 0.3, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.3, y: 0.5)
                    )
                )
                .frame(width: geo.size.width * widthRatio, height: 12)
        }
        .frame(height: 12)
    }
}
