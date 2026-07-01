import SwiftUI

/// Professional dictionary card — word header, phonetic, colour-coded POS definitions, examples.
struct DictionaryCardView: View {
    let entry: DictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordHeader
            if !entry.phonetic.isEmpty { phoneticRow }
            if !entry.definitions.isEmpty {
                Divider().padding(.vertical, AppTheme.spaceSM)
                definitionsList
            }
            if !entry.examples.isEmpty {
                Divider().padding(.vertical, AppTheme.spaceSM)
                examplesList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Word header
    private var wordHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "character.book.closed.fill")
                .font(.title3).foregroundColor(AppTheme.textAccent)
            Text(entry.word)
                .font(.system(size: AppTheme.fontSizeTitle + 2, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
        }.padding(.bottom, AppTheme.spaceXS)
    }

    // MARK: - Phonetic
    private var phoneticRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").font(.caption2).foregroundColor(AppTheme.textSecondary)
            Text(entry.phonetic)
                .font(.system(size: AppTheme.fontSizeBody, design: .monospaced)).foregroundColor(AppTheme.textSecondary)
        }
    }

    // MARK: - Definitions
    private var definitionsList: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            ForEach(entry.definitions) { def in
                HStack(alignment: .top, spacing: AppTheme.spaceSM) {
                    Text(def.pos)
                        .font(.caption2).fontWeight(.bold).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(posColor(def.pos)))
                    Text(def.meaning)
                        .font(.system(size: AppTheme.fontSizeBody)).foregroundColor(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Examples
    private var examplesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entry.examples.enumerated()), id: \.element.id) { idx, ex in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("\(idx + 1).").font(.caption2).foregroundColor(AppTheme.textSecondary)
                            .frame(width: 14, alignment: .trailing)
                        Text(ex.en).font(.system(size: AppTheme.fontSizeLabel)).italic().foregroundColor(AppTheme.textPrimary)
                    }
                    Text(ex.zh).font(.caption2).foregroundColor(AppTheme.textSecondary).padding(.leading, 18)
                }
            }
        }
    }

    // MARK: - POS colour
    private func posColor(_ pos: String) -> Color {
        let lower = pos.lowercased()
        if lower.contains("noun") || lower.contains("n.")  { return .blue }
        if lower.contains("verb") || lower.contains("v.")  { return .orange }
        if lower.contains("adj")  || lower.contains("a.")  { return .green }
        if lower.contains("adv")  || lower.contains("ad.") { return .purple }
        if lower.contains("prep") { return .pink }
        if lower.contains("conj") { return .teal }
        if lower.contains("pron") { return .indigo }
        if lower.contains("interj") { return .red }
        return .gray
    }
}
