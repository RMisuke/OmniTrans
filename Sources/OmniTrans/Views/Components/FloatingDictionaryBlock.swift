import SwiftUI

/// Dictionary engine router with Action Blue accent.
struct FloatingDictionaryBlock: View {
    let isNativeDict: Bool
    var onRetry: (() -> Void)?

    @Environment(TranslationSessionStore.self) private var session

    var body: some View {
        Group {
            if session.isTranslating { loadingContent }
            else if let entry = session.dictionaryEntry, entry.isWord { entryContent(entry) }
            else if let err = session.errorMessage { errorContent(err) }
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 14) {
            SkeletonShimmerView(compact: true).padding(.horizontal, 60)
            Text("正在查询词典…").font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 24)
    }

    private func entryContent(_ entry: DictionaryEntry) -> some View {
        ScrollView {
            Group { if isNativeDict { NativeDictionaryView(entry: entry) } else { DictionaryCardView(entry: entry) } }
                .padding(.horizontal, 14).padding(.vertical, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.caption).foregroundColor(.red).lineLimit(4)
            Button(action: { onRetry?() }) { Label("重试", systemImage: "arrow.clockwise").font(.caption2) }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(AppTheme.accentAction).disabled(session.isTranslating)
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }
}
