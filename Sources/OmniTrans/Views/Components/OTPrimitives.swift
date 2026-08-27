import SwiftUI

// MARK: - OmniTrans v0.8 复用组件库
//
// 「哑光画布 + 玻璃悬浮件」双层模型的标准构件。
// 所有组件基于 AppTheme.MaterialPolicy 实底表面，禁止内容区毛玻璃。

/// 标准卡片容器 —— 实底表面 + hairline 描边，替代一切内容区毛玻璃。
struct OTCard<Content: View>: View {
    var spacing: CGFloat = AppTheme.spaceSM
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(AppTheme.spaceMD)
            .frame(maxWidth: .infinity, alignment: .leading)
            .solidCardSurface(in: RoundedRectangle(cornerRadius: AppTheme.radiusMD, style: .continuous))
    }
}

/// 表单标准行 —— 左对齐标签（固定宽度）+ 右侧控件。
/// 替代各视图手写的 `editorField`/`ProviderRow` 等私有实现。
struct FormRow<Control: View>: View {
    let label: String
    var labelWidth: CGFloat = 72
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: AppTheme.spaceSM) {
            Text(label)
                .font(.system(size: AppTheme.fontSizeFine, weight: .medium))
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: labelWidth, alignment: .leading)
            control()
        }
    }
}

/// 分组标题 —— 小型大写风格，带可选系统图标。
struct SectionHeader: View {
    let title: String
    var systemImage: String?

    var body: some View {
        Label {
            Text(title.uppercased())
                .font(.system(size: AppTheme.fontSizeMicro, weight: .bold))
                .foregroundColor(AppTheme.textSecondary)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.fontSizeMicro, weight: .bold))
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }
}

/// 工具条胶囊按钮 —— 悬浮控件白名单内的标准按钮。
/// macOS 26+ 使用 Liquid Glass；更早版本实底回退。
struct ToolbarCapsuleButton: View {
    let systemImage: String
    let helpText: String
    var label: String? = nil
    var isProminent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.fontSizeFine))
                if let label {
                    Text(label)
                        .font(.system(size: AppTheme.fontSizeFine, weight: .semibold))
                }
            }
            .foregroundColor(isProminent ? .white : AppTheme.textPrimary)
            .padding(.horizontal, label == nil ? 8 : 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background {
            let shape = RoundedRectangle(cornerRadius: AppTheme.radiusSM, style: .continuous)
            if isProminent {
                shape.fill(AppTheme.accentAction)
            } else {
                Group {
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: shape)
                    } else {
                        AppTheme.MaterialPolicy.cardBackground
                            .overlay(shape.strokeBorder(AppTheme.MaterialPolicy.cardStroke))
                            .clipShape(shape)
                    }
                }
            }
        }
        .help(helpText)
    }
}

/// 状态指示点 —— 支持呼吸动画的连接状态灯。
struct StatusDot: View {
    let color: Color
    var isBreathing: Bool = false

    @State private var phase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(isBreathing ? (phase ? 0.35 : 1.0) : 1.0)
            .animation(
                isBreathing
                    ? Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                    : nil,
                value: phase
            )
            .onAppear { if isBreathing { phase = true } }
            .onChange(of: isBreathing) { _, newValue in phase = newValue }
    }
}
