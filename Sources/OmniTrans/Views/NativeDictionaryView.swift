import SwiftUI

/// Apple Dictionary.app‑style layout.  Serif word header, accent divider,
/// zebra-striped definition rows with POS badges.
struct NativeDictionaryView: View {
    let entry: DictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.word)
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundColor(AppTheme.textPrimary)
                .padding(.bottom, 10)

            Rectangle()
                .fill(AppTheme.textAccent).frame(height: 2).frame(maxWidth: 60)
                .padding(.bottom, 14)

            if entry.definitions.isEmpty {
                emptyState
            } else {
                ForEach(Array(entry.definitions.enumerated()), id: \.element.id) { idx, def in
                    definitionRow(def, index: idx)
                }
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        HStack(spacing: AppTheme.spaceSM) {
            Image(systemName: "magnifyingglass").foregroundColor(AppTheme.textSecondary)
            Text("系统词典未收录该词").font(.system(size: AppTheme.fontSizeBody)).foregroundColor(AppTheme.textSecondary)
        }.padding(.vertical, AppTheme.spaceMD)
    }

    private func definitionRow(_ def: DictionaryEntry.Definition, index: Int) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
            HStack(spacing: 6) {
                if def.pos != "—" && !def.pos.isEmpty {
                    Text(def.pos).font(.caption).fontWeight(.semibold)
                        .foregroundColor(AppTheme.textAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(AppTheme.textAccent.opacity(0.1)))
                }
                Text("\(index + 1).").font(.caption2).foregroundColor(AppTheme.textTertiary)
            }
            Text(def.meaning)
                .font(.system(size: AppTheme.fontSizeBody)).foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
        }
        .padding(.vertical, 6).padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(index % 2 == 0 ? Color.clear : AppTheme.bgSubtle.opacity(0.3))
        )
    }
}
