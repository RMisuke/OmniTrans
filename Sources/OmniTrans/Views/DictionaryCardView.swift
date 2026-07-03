import SwiftUI

/// Professional dictionary card with staggered entrance and hover micro-interactions.
/// All staggered animations are gated by the global "动画效果" toggle.
struct DictionaryCardView: View {
    let entry: DictionaryEntry
    @AppStorage("animations_enabled") private var animationsEnabled = true

    @State private var showHeader = false
    @State private var showPhonetic = false
    @State private var showDefinitions = false
    @State private var showExamples = false

    private var springFast: Animation? {
        animationsEnabled ? .spring(response: 0.32, dampingFraction: 0.78) : nil
    }
    private var springMedium: Animation? {
        animationsEnabled ? .spring(response: 0.28, dampingFraction: 0.75) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader { wordHeader.transition(.opacity.combined(with: .move(edge: .top))) }
            if showPhonetic, !entry.phonetic.isEmpty { phoneticRow.transition(.opacity) }
            if showDefinitions, !entry.definitions.isEmpty {
                Divider().padding(.vertical, AppTheme.spaceSM)
                definitionsList.transition(.opacity.combined(with: .move(edge: .leading)))
            }
            if showExamples, !entry.examples.isEmpty {
                Divider().padding(.vertical, AppTheme.spaceSM)
                examplesList.transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animateIn() }
        .onChange(of: entry.word) { _ in animateIn() }
        .animation(springFast, value: showHeader)
        .animation(springMedium?.delay(0.04), value: showPhonetic)
        .animation(springMedium?.delay(0.08), value: showDefinitions)
        .animation(springMedium?.delay(0.12), value: showExamples)
    }

    private func animateIn() {
        showHeader = false; showPhonetic = false; showDefinitions = false; showExamples = false
        withAnimationGated(.spring(response: 0.3, dampingFraction: 0.75)) { showHeader = true }
        withAnimationGated(.spring(response: 0.28, dampingFraction: 0.75).delay(0.04)) { showPhonetic = true }
        withAnimationGated(.spring(response: 0.28, dampingFraction: 0.75).delay(0.08)) { showDefinitions = true }
        withAnimationGated(.spring(response: 0.28, dampingFraction: 0.75).delay(0.12)) { showExamples = true }
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
                DefinitionRowView(def: def, posColor: posColor)
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

/// Individual definition row with hover micro-interaction.
private struct DefinitionRowView: View {
    let def: DictionaryEntry.Definition
    let posColor: (String) -> Color
    @AppStorage("animations_enabled") private var animationsEnabled = true
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.spaceSM) {
            Text(def.pos)
                .font(.caption2).fontWeight(.bold).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(posColor(def.pos)))
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .shadow(color: posColor(def.pos).opacity(isHovered ? 0.35 : 0), radius: 4, y: 1)
                .animation(animationsEnabled ? .spring(response: 0.2, dampingFraction: 0.7) : nil, value: isHovered)
            Text(def.meaning)
                .font(.system(size: AppTheme.fontSizeBody)).foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onHover { hovering in isHovered = hovering }
    }
}
