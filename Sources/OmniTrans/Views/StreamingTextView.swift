import SwiftUI

// MARK: - Streaming Text View (Performance-Isolated)

/// Isolated sub-view for streaming and final translated text.
///
/// ## Performance Architecture
///
/// This view observes `TranslationSessionStore` via `@Environment` for
/// **field-level** SwiftUI observation.  Because `TranslationSessionStore`
/// is `@Observable`, high-frequency mutations to `session.translatedText`
/// (SSE token appends) trigger body recomputation **only** within this
/// view — the outer `FloatingTranslationView` chrome and its
/// `AdaptiveGlassBackground` are **not** invalidated.
///
/// ## Metal Acceleration
///
/// The text block is wrapped in `.drawingGroup()` which flattens the
/// entire text subtree into a single Core Animation `CAMetalLayer`.
/// This offloads layout composition to the GPU and eliminates per-glyph
/// CPU layout passes during high-frequency stream updates.
///
/// ## Cursor Isolation
///
/// The blinking cursor is extracted into a dedicated `BlinkingCursor`
/// sub-view with its own `@State`-driven animation.  Timer ticks that
/// toggle cursor visibility do **not** invalidate the `.drawingGroup()`
/// text layer, preventing layout-bound re-measurement of parent
/// containers.
struct StreamingTextView: View {
    @Environment(TranslationSessionStore.self) private var session

    var body: some View {
        Group {
            if session.isTranslating {
                streamingContent
            } else if !session.translatedText.isEmpty {
                finalContent
            } else {
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - Streaming Content

    @ViewBuilder
    private var streamingContent: some View {
        if session.translatedText.isEmpty {
            // Shimmer placeholder — pre-streaming, no text yet
            SkeletonShimmerView()
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    // ── Text block: Metal-accelerated, field-level observed ──
                    Text(session.translatedText)
                        .font(.system(size: AppTheme.fontSizeBody))
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .drawingGroup()          // GPU-offloaded composition

                    // ── Blinking cursor: isolated animation, zero layout impact ──
                    BlinkingCursor()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    // MARK: - Final Content (translation complete)

    private var finalContent: some View {
        ScrollView {
            Text(session.translatedText)
                .font(.system(size: AppTheme.fontSizeBody))
                .textSelection(.enabled)
                .lineSpacing(4)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .drawingGroup()
        }
    }
}

// MARK: - Blinking Cursor

/// Self-contained blinking cursor that manages its own timer and
/// animation lifecycle.  Rendering is intentionally isolated from
/// the streaming text block so that cursor ticks never invalidate
/// the `.drawingGroup()` Metal layer or trigger parent layout
/// re-measurement.
///
/// - **Timer**: 0.53 s interval, toggles visibility on the main actor.
/// - **Layout**: Fixed 2×15 pt rectangle — no dependency on parent
///   geometry or text metrics.
private struct BlinkingCursor: View {
    @State private var isVisible: Bool = true
    @State private var timer: Timer?

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: 15)
            .opacity(isVisible ? 1 : 0)
            .animation(AppTheme.Motion.snip.gated, value: isVisible)
            .onAppear { start() }
            .onDisappear { stop() }
    }

    private func start() {
        isVisible = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [self] _ in
            // Capture `self` strongly to keep the cursor alive as long
            // as the timer runs.  `stop()` invalidates the timer on
            // disappear, breaking the retain cycle.
            // Toggle on the next runloop iteration so the timer fire
            // doesn't synchronously mutate @State during body evaluation.
            DispatchQueue.main.async {
                self.isVisible.toggle()
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isVisible = false
    }
}
