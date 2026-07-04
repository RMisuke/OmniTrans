import SwiftUI

/// Simple dictionary entry rendering — word header + flat definition list.
struct NativeDictionaryView: View {
    let entry: DictionaryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.word)
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundColor(AppTheme.textPrimary)
                        .padding(.bottom, 4)
                    if !entry.phonetic.isEmpty {
                        Text(entry.phonetic)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    Rectangle()
                        .fill(AppTheme.accentAction).frame(height: 2).frame(maxWidth: 60)
                        .padding(.vertical, 10)
                }

                if entry.definitions.isEmpty {
                    HStack(spacing: AppTheme.spaceSM) {
                        Image(systemName: "magnifyingglass").foregroundColor(AppTheme.textSecondary)
                        Text("系统词典未收录该词").font(.system(size: AppTheme.fontSizeBody)).foregroundColor(AppTheme.textSecondary)
                    }.padding(.vertical, AppTheme.spaceMD)
                }

                ForEach(Array(entry.definitions.enumerated()), id: \.element.id) { idx, def in
                    HStack(alignment: .top, spacing: 6) {
                        Text(def.pos).font(.caption).fontWeight(.semibold)
                            .foregroundColor(AppTheme.accentAction)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(AppTheme.accentAction.opacity(0.1)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(def.meaning)
                                .font(.system(size: AppTheme.fontSizeBody))
                                .foregroundColor(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(idx % 2 == 0 ? Color.clear : AppTheme.bgSubtle.opacity(0.3)))
                }

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .id(entry.word)
    }
}
