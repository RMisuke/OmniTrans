import SwiftUI

// MARK: - Settings · 关于 Tab（自 SettingsPanelContent 拆分）

extension SettingsPanelContent {

    var aboutTab: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon with bouncy entrance
            Image(nsImage: appIcon(size: 72))
                .resizable().frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                .scaleEffect(cardsVisible ? 1.0 : 0.8)
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.iconEntrance.resolveGated()?.delay(0.05), value: cardsVisible)

            Spacer().frame(height: 14)

            Text("OmniTrans")
                .font(.system(size: 22, weight: .bold))
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.1), value: cardsVisible)

            Text("macOS 智能翻译 · 词典 · OCR · 离线翻译")
                .font(.system(size: AppTheme.fontSizeFine))
                .foregroundColor(.secondary)
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.14), value: cardsVisible)

            Spacer().frame(height: 4)

            Text("版本 \(kAppVersion)")
                .font(.system(size: AppTheme.fontSizeFine, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.18), value: cardsVisible)

            Spacer().frame(height: 20)

            // Feature list with stagger
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(features.enumerated()), id: \.offset) { i, featItem in
                    featureRow(icon: featItem.icon, text: featItem.text, index: i)
                }
            }.padding(.horizontal, 28)

            Spacer()

            // ── OCR 预热状态 ──
            OCRWarmupStatusSection()
                .padding(.horizontal, 28)
                .opacity(cardsVisible ? 1 : 0)
                .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.35), value: cardsVisible)

            Spacer().frame(height: 8)

            Button("重新显示引导") {
                UserDefaults.standard.set(false, forKey: "has_completed_onboarding")
                if let w = NSApp.keyWindow { w.close() }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("OmniTransShowOnboarding"),
                        object: nil
                    )
                }
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundColor(.accentColor)
            .font(.system(size: AppTheme.fontSizeFine))
            .opacity(cardsVisible ? 1 : 0)

            Spacer().frame(height: 8)
        }.frame(maxWidth: .infinity)
    }

    func featureRow(icon: String, text: String, index: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.fontSizeFine, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 16)
            Text(text)
                .font(.system(size: AppTheme.fontSizeFine))
                .foregroundColor(.primary)
        }
        .opacity(cardsVisible ? 1 : 0)
        .offset(y: cardsVisible ? 0 : 6)
        .animation(
            AppTheme.Motion.featureStagger.resolveGated()?.delay(Double(index) * 0.05),
            value: cardsVisible
        )
    }

    func appIcon(size: CGFloat) -> NSImage {
        if let path = Bundle.main.path(forResource: "icon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            let r = NSImage(size: NSSize(width: size, height: size))
            r.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                      from: .zero, operation: .copy, fraction: 1)
            r.unlockFocus()
            return r
        }
        return NSImage(systemSymbolName: "character.bubble.fill",
                       accessibilityDescription: nil)!
    }
}

// MARK: - OCR Warmup Status Section

/// 关于页底部的 OCR ANE 预热状态指示器。
/// 实时反映预热进度 / 成功 / 失败 / 重试中。
private struct OCRWarmupStatusSection: View {
    @State private var warmup = OCRWarmupState.shared

    var body: some View {
        HStack(spacing: 8) {
            // 状态图标
            if warmup.isWarmingUp {
                ProgressView(value: warmup.progress)
                    .frame(width: 60)
            } else if warmup.warmupFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 11))
            }

            // 状态文字
            Text(statusText)
                .font(.system(size: AppTheme.fontSizeFine))
                .foregroundColor(.secondary)

            Spacer()

            // 重试按钮（仅预热失败时显示）
            if warmup.warmupFailed {
                Button("重试") {
                    warmup.retryWarmup()
                }
                .font(.system(size: AppTheme.fontSizeFine, weight: .medium))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.radiusSM, style: .continuous)
                .fill(AppTheme.MaterialPolicy.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radiusSM, style: .continuous)
                .strokeBorder(AppTheme.MaterialPolicy.cardStroke, lineWidth: 1)
        )
    }

    private var statusText: String {
        if warmup.isWarmingUp {
            let pct = Int(warmup.progress * 100)
            return "OCR 引擎预热中… \(pct)%"
        } else if warmup.warmupFailed {
            return "OCR 引擎预热未就绪，可点击重试"
        } else {
            return "OCR 引擎已就绪"
        }
    }
}
