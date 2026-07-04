import SwiftUI

// MARK: - Dictionary Card View (Staggered Entrance)

/// 词典卡片，使用 ``StaggeredEntranceContainer`` 实现声明式错列入场。
///
/// ## 架构改进
///
/// - **旧实现**：4 个 `@State` 布尔 + `animateIn()` 复位函数 + 硬编码
///   `.delay(0.04)` / `.delay(0.08)` / `.delay(0.12)`
/// - **新实现**：零 `@State`、零 `animateIn`。每个 section 包裹在
///   `StaggeredEntranceContainer` 中，延迟由 `IndexCounter` 动态分配。
///   卡片通过 `.id(entry.word)` 强制在查词切换时完整重建，自然触发
///   所有子容器的 `.onAppear` 入场动画。
///
/// - `nativeCardStyle()` 提供高不透明度纯色背景 + 0.5pt 发丝环。
struct DictionaryCardView: View {
    let entry: DictionaryEntry

    var body: some View {
        let counter = IndexCounter()
        VStack(alignment: .leading, spacing: 0) {
            // Index 0: 词头（必定显示）
            StaggeredEntranceContainer(index: counter.next) {
                wordHeader
            }

            // Index 1: 音标（条件显示）
            if !entry.phonetic.isEmpty {
                StaggeredEntranceContainer(index: counter.next) {
                    phoneticRow
                }
            }

            // Index N: 释义（条件显示）
            if !entry.definitions.isEmpty {
                Divider().padding(.vertical, AppTheme.spaceXS)
                StaggeredEntranceContainer(index: counter.next) {
                    definitionsList
                }
            }

            // Index N: 例句（条件显示）
            if !entry.examples.isEmpty {
                Divider().padding(.vertical, AppTheme.spaceXS)
                StaggeredEntranceContainer(index: counter.next) {
                    examplesList
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeCardStyle()
        .id(entry.word)  // 强制重建 → 重新触发所有入场动画
    }

    // MARK: - Sections

    private var wordHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "character.book.closed.fill")
                .font(.title3)
                .foregroundColor(AppTheme.accentAction)
            Text(entry.word)
                .font(.system(size: AppTheme.fontSizeTitle, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
        }
        .padding(.bottom, AppTheme.spaceXXS)
    }

    private var phoneticRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
            Text(entry.phonetic)
                .font(.system(size: AppTheme.fontSizeBody, design: .monospaced))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var definitionsList: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
            ForEach(entry.definitions) { def in
                DefinitionRowView(def: def, posColor: posColor)
            }
        }
    }

    private var examplesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entry.examples.enumerated()), id: \.element.id) { idx, ex in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("\(idx + 1).")
                            .font(.caption2)
                            .foregroundColor(AppTheme.textSecondary)
                            .frame(width: 14, alignment: .trailing)
                        Text(ex.en)
                            .font(.system(size: AppTheme.fontSizeCaption))
                            .italic()
                            .foregroundColor(AppTheme.textPrimary)
                    }
                    Text(ex.zh)
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(.leading, 18)
                }
            }
        }
    }

    // MARK: - POS Color Mapping

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

// MARK: - Definition Row

private struct DefinitionRowView: View {
    let def: DictionaryEntry.Definition
    let posColor: (String) -> Color

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.spaceXS) {
            Text(def.pos)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(posColor(def.pos))
                )
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .shadow(
                    color: posColor(def.pos).opacity(isHovered ? 0.35 : 0),
                    radius: 4, y: 1
                )
                .animation(AppTheme.Motion.snip.gated, value: isHovered)

            Text(def.meaning)
                .font(.system(size: AppTheme.fontSizeBody))
                .foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onHover { hovering in isHovered = hovering }
    }
}
