import SwiftUI

// MARK: - Settings 卡片容器与共享小组件

extension SettingsPanelContent {

    /// Card with staggered entrance + hover scale feedback.
    /// v0.8：实底表面替代 `.regularMaterial`，阴影减淡 —— 内容区禁止毛玻璃。
    func animatedCard<Content: View>(icon: String, title: String, index: Int,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: AppTheme.fontSizeFine, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }.padding(.bottom, 8)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.MaterialPolicy.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.MaterialPolicy.cardStroke, lineWidth: 0.5))
                // v0.8：hover 反馈改为描边强调，去掉大面积投影。
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(hoveredCardIndex == index ? 0.35 : 0))
                        .animation(AppTheme.Motion.buttonHover.resolveGated(), value: hoveredCardIndex == index)
                )
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .opacity(cardsVisible ? 1 : 0)
        .offset(y: cardsVisible ? 0 : 8)
        .animation(
            AppTheme.Motion.panelOpen.resolveGated()?.delay(Double(index) * 0.06),
            value: cardsVisible
        )
        .onHover { hovering in
            withAnimation(AppTheme.Motion.buttonHover.resolveGated()) {
                hoveredCardIndex = hovering ? index : nil
            }
        }
    }

    /// 通用「恢复默认」小按钮 —— 翻译 Tab 与通用 Tab 共用。
    func resetButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: AppTheme.fontSizeFine))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Value Pulse Modifier

/// Subtle scale pulse on numeric value changes — used for slider value labels.
struct ValuePulseModifier: ViewModifier {
    let trigger: AnyHashable
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.12 : 1.0)
            .animation(AppTheme.Motion.sliderValuePulse.resolveGated(), value: pulsing)
            .onChange(of: trigger) { _, _ in
                pulsing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    pulsing = false
                }
            }
    }
}
