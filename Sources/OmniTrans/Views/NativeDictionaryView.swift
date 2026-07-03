import SwiftUI

/// Apple Dictionary.app‑style layout with staggered entrance animation.
/// All staggered animations are gated by the global "动画效果" toggle.
struct NativeDictionaryView: View {
    let entry: DictionaryEntry
    @AppStorage("animations_enabled") private var animationsEnabled = true

    @State private var showHeader = false
    @State private var showDefs = false

    private var springFast: Animation? {
        animationsEnabled ? .spring(response: 0.3, dampingFraction: 0.78) : nil
    }
    private var springMedium: Animation? {
        animationsEnabled ? .spring(response: 0.28, dampingFraction: 0.75) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                Text(entry.word)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundColor(AppTheme.textPrimary)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                Rectangle()
                    .fill(AppTheme.textAccent).frame(height: 2).frame(maxWidth: 60)
                    .padding(.bottom, 14)
                    .transition(.scale(scale: 0, anchor: .leading).combined(with: .opacity))
            }

            if showDefs {
                if entry.definitions.isEmpty {
                    emptyState.transition(.opacity)
                } else {
                    ForEach(Array(entry.definitions.enumerated()), id: \.element.id) { idx, def in
                        definitionRow(def, index: idx)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .leading)),
                                removal: .identity
                            ))
                    }
                }
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .onAppear { animateIn() }
        .onChange(of: entry.word) { _ in animateIn() }
        .animation(springFast, value: showHeader)
        .animation(springMedium?.delay(0.06), value: showDefs)
    }

    private func animateIn() {
        showHeader = false; showDefs = false
        withAnimationGated(.spring(response: 0.3, dampingFraction: 0.75)) { showHeader = true }
        withAnimationGated(.spring(response: 0.28, dampingFraction: 0.75).delay(0.06)) { showDefs = true }
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
