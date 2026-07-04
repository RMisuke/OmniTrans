import SwiftUI

// MARK: - Floating Source Block (Styled Container)

/// Displays the user's source text inside a crisp rounded container
/// with adaptive card coloring and a subtle drop shadow.
///
/// - **Dark mode**: `#292a2b` background.
/// - **Light mode**: `#f7f7f7` background.
/// - **Shadow**: `black.opacity(0.12)`, 6pt radius, 3pt y-offset.
/// - **Corners**: 12pt continuous radius.
struct FloatingSourceBlock: View {
    @Environment(TranslationSessionStore.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            if session.detectedIsWord {
                wordDetectionBadge
            }
            ScrollView {
                Text(session.inputText)
                    .font(.system(size: 16))
                    .textSelection(.enabled)
                    .foregroundColor(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 52, maxHeight: 80)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    // MARK: - Word Detection Badge

    private var wordDetectionBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "character.book.closed.fill")
                .font(.caption2)
                .foregroundColor(AppTheme.accentAction)
            Text("检测到单词 — 词典模式")
                .font(.system(size: 10))
                .foregroundColor(AppTheme.accentAction)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Capsule().fill(AppTheme.accentAction.opacity(0.08)))
        .padding(.bottom, 6)
    }
}
