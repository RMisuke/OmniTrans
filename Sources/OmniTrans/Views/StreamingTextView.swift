import SwiftUI

/// Isolated sub-view for streaming and final translated text.
///
/// Observes `TranslationSessionStore` via `@Environment` for field-level
/// SwiftUI observation — only this view recomputes on text changes,
/// not the outer `FloatingTranslationView` chrome.
struct StreamingTextView: View {
    @Environment(TranslationSessionStore.self) private var session

    @State private var showCursor = true
    @State private var cursorTimer: Timer?

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
        .onAppear { if session.isTranslating { startCursor() } }
        .onDisappear { stopCursor() }
        .onChange(of: session.isTranslating) { _, streaming in
            streaming ? startCursor() : stopCursor()
        }
    }

    // MARK: - Streaming

    @ViewBuilder
    private var streamingContent: some View {
        if session.translatedText.isEmpty {
            // Shimmer — no ScrollView wrapper so GeometryReader gets proper width
            SkeletonShimmerView()
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    Text(session.translatedText)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .drawingGroup()
                    if showCursor {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: 15)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    // MARK: - Final

    private var finalContent: some View {
        ScrollView {
            Text(session.translatedText)
                .font(.system(size: 15))
                .textSelection(.enabled)
                .lineSpacing(4)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .drawingGroup()
        }
    }

    // MARK: - Cursor

    private func startCursor() {
        showCursor = true
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { _ in
            showCursor.toggle()
        }
    }

    private func stopCursor() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        showCursor = false
    }
}
