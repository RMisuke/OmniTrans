import SwiftUI

// MARK: - Unified Design System

/// Centralised colour palette.  Uses `NSColor` bridged values so every
/// colour automatically tracks the system appearance (light / dark).
enum AppTheme {

    // ── Text colours ──
    static let textPrimary  = Color(nsColor: .textColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary  = Color(nsColor: .tertiaryLabelColor)
    static let textAccent    = Color.accentColor

    // ── Backgrounds ──
    /// Solid system background — no translucency.  Best for menu-bar content.
    static let bgSolid       = Color(nsColor: .controlBackgroundColor)
    /// Subtle filled background for grouping / cards.
    static let bgSubtle      = Color(nsColor: .quaternaryLabelColor)
    /// Slightly elevated background.
    static let bgElevated    = Color(nsColor: .windowBackgroundColor)
    /// Material with system vibrancy — good for floating panels.
    static let bgFloating    = Material.regularMaterial

    // ── Borders & separators ──
    static let border        = Color(nsColor: .separatorColor)
    static let borderSubtle  = Color(nsColor: .separatorColor).opacity(0.5)

    // ── Semantic ──
    static let success = Color.green
    static let error   = Color.red
    static let warning = Color.orange

    // ── Font sizes ──
    static let fontSizeCaption  = 11.0
    static let fontSizeLabel    = 12.0
    static let fontSizeBody     = 14.0
    static let fontSizeHeadline = 16.0
    static let fontSizeTitle    = 20.0

    // ── Spacing ──
    static let spaceXS = 4.0
    static let spaceSM = 8.0
    static let spaceMD = 12.0
    static let spaceLG = 16.0
}

// MARK: - View extensions for common patterns

extension View {

    /// Applies a card-style background with optional border.
    func cardStyle(
        bg: Color = AppTheme.bgSubtle,
        cornerRadius: CGFloat = 8
    ) -> some View {
        self
            .background(bg.opacity(0.5))
            .cornerRadius(cornerRadius)
    }

    /// Standard label row (icon + text) used in settings / info headers.
    func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: AppTheme.fontSizeHeadline, weight: .semibold))
            .foregroundColor(AppTheme.textPrimary)
    }

    /// Pills / badges for small metadata.
    func badgeStyle(_ bg: Color = AppTheme.bgSubtle) -> some View {
        self
            .font(.system(size: AppTheme.fontSizeCaption, weight: .medium))
            .foregroundColor(AppTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .cornerRadius(4)
    }

    /// Small help / hint text.
    func hintStyle() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeCaption))
            .foregroundColor(AppTheme.textTertiary)
    }

    /// Accent-coloured word-detection hint bar.
    func wordHintBar() -> some View {
        self
            .font(.system(size: 10))
            .foregroundColor(AppTheme.textAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(AppTheme.textAccent.opacity(0.08))
            .cornerRadius(4)
    }

    /// Floating panel root: material background + border + rounded corners.
    func floatingPanelStyle(
        minWidth: CGFloat = 360,
        minHeight: CGFloat = 380,
        cornerRadius: CGFloat = 14
    ) -> some View {
        self
            .frame(minWidth: minWidth, minHeight: minHeight)
            .background(AppTheme.bgFloating)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            )
    }
}
