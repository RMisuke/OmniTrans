import SwiftUI

// MARK: - macOS 26 Native Design System (Apple HIG-aligned)

/// Centralised design-token palette aligned with Apple's design language
/// (DESIGN-apple.md) — Action Blue (#0066cc), matte high-opacity
/// materials, tight typography, and 8px-base spacing.
///
/// ## Key Principles
/// - **Single accent**: Action Blue (#0066cc) for all interactive elements.
/// - **High-opacity materials**: `.ultraThickMaterial` or solid system
///   colours — no muddy low-opacity web-tiles.
/// - **"Solid Top, Thick Bottom"**: Opaque toolbars with hairline dividers
///   over thick material content canvases.
/// - **Vector-sharp text**: No `.drawingGroup()` scaling, no blur.
enum AppTheme {

    // MARK: - Apple Design System Colors

    /// Action Blue — the single brand accent (#0066cc).  All links,
    /// primary buttons, and focus signals use this colour.
    static let accentAction = Color(red: 0x00/255, green: 0x66/255, blue: 0xCC/255)

    /// Near-black ink for headlines and body on light surfaces (#1d1d1f).
    static let ink = Color(red: 0x1D/255, green: 0x1D/255, blue: 0x1F/255)

    /// White text for dark surfaces.
    static let onDark = Color.white

    /// Parchment off-white canvas (#f5f5f7).
    static let parchment = Color(red: 0xF5/255, green: 0xF5/255, blue: 0xF7/255)

    /// Dark tile surface (#272729).
    static let darkTile = Color(red: 0x27/255, green: 0x27/255, blue: 0x29/255)

    // MARK: - Text colours (system-native)

    static let textPrimary   = Color(nsColor: .textColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary  = Color(nsColor: .tertiaryLabelColor)

    /// Low-noise caption / legal grey — #8b8b8b.
    /// Used for auxiliary hint text that must remain visually subdued
    /// without disappearing entirely.  Strictly #8b8b8b, not system-dependent.
    static let textCaptionGray = Color(red: 139.0/255, green: 139.0/255, blue: 139.0/255)

    // MARK: - High-opacity backgrounds

    /// Solid window background — opaque matte for toolbars/headers.
    static let bgSolid     = Color(nsColor: .windowBackgroundColor)
    /// Thick material for content canvases — heavy blur backbone.
    static let bgThick     = Material.ultraThickMaterial
    /// Control background for form rows.
    static let bgControl   = Color(nsColor: .controlBackgroundColor)

    // MARK: - Adaptive card surfaces (precise hex)

    /// Card background: `#292a2b` dark / `#f7f7f7` light.
    static let cardSurface: Color = {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0x29/255, green: 0x2A/255, blue: 0x2B/255, alpha: 1)
            }
            return NSColor(red: 0xF7/255, green: 0xF7/255, blue: 0xF7/255, alpha: 1)
        })
    }()

    // MARK: - Borders & separators

    /// Hairline divider — 0.5pt crisp line.
    static let hairline     = Color.primary.opacity(0.12)
    /// Card border — subtle ring.
    static let cardBorder   = Color.primary.opacity(0.08)

    // MARK: - Semantic (backward-compatible aliases)

    static let success = IndicatorColor.success.color
    static let error   = IndicatorColor.error.color
    static let warning = Color.orange

    // MARK: - Control tints

    static let toggleTint = Color(nsColor: .controlAccentColor)

    // MARK: - Backward-compatible aliases (existing call sites)

    static let textAccent = accentAction
    static let bgSubtle   = Color(nsColor: .quaternaryLabelColor)

    // MARK: - Typography (DESIGN-apple.md aligned)

    static let fontSizeMicro    = 10.0   // micro-legal
    static let fontSizeFine     = 12.0   // fine-print, nav-link
    static let fontSizeCaption  = 14.0   // caption
    static let fontSizeBody     = 17.0   // body (Apple standard)
    static let fontSizeHeadline = 17.0   // body-strong
    static let fontSizeTitle    = 21.0   // tagline

    // MARK: - Spacing (8px base, DESIGN-apple.md aligned)

    static let spaceXXS = 4.0
    static let spaceXS  = 8.0
    static let spaceSM  = 12.0   // primary component padding
    static let spaceMD  = 17.0   // card internal spacing
    static let spaceLG  = 24.0
    static let spaceXL  = 32.0

    // MARK: - Corner radii (DESIGN-apple.md aligned)

    static let radiusXS  : CGFloat = 5.0
    static let radiusSM  : CGFloat = 8.0    // utility buttons, cards
    static let radiusMD  : CGFloat = 11.0   // pearl buttons
    static let radiusLG  : CGFloat = 18.0   // utility cards
    static let radiusPill: CGFloat = 9999.0 // primary CTAs
}

// MARK: - Indicator Colors

extension AppTheme {

    enum IndicatorColor: CaseIterable {
        case loading
        case success
        case error

        var color: Color {
            switch self {
            case .loading: Color(red: 0.980, green: 0.784, blue: 0.000)  // #fac800
            case .success: Color(red: 0.204, green: 0.831, blue: 0.600)  // #34d399
            case .error:   Color(red: 1.000, green: 0.361, blue: 0.376)  // #ff5c60
            }
        }
    }
}

// MARK: - View Extensions

extension View {

    // ── Legacy card style (preserved for compatibility) ──

    func cardStyle(bg: Color = AppTheme.bgControl, cornerRadius: CGFloat = AppTheme.radiusSM) -> some View {
        self.background(bg).cornerRadius(cornerRadius)
    }

    func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: AppTheme.fontSizeHeadline, weight: .semibold))
            .foregroundColor(AppTheme.textPrimary)
    }

    func badgeStyle(_ bg: Color = AppTheme.bgControl) -> some View {
        self
            .font(.system(size: AppTheme.fontSizeCaption, weight: .medium))
            .foregroundColor(AppTheme.textPrimary)
            .padding(.horizontal, AppTheme.spaceXS)
            .padding(.vertical, 3)
            .background(bg)
            .cornerRadius(AppTheme.radiusXS)
    }

    func hintStyle() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeFine))
            .foregroundColor(AppTheme.textTertiary)
    }

    func wordHintBar() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeMicro))
            .foregroundColor(AppTheme.accentAction)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(AppTheme.accentAction.opacity(0.08))
            .cornerRadius(AppTheme.radiusXS)
    }

    // MARK: - macOS Native Card Style

    /// Apple-native utility card: high-opacity solid background,
    /// 0.5pt hairline ring, 18pt continuous radius, 17pt internal padding.
    ///
    /// Replaces the old `glassCardStyle()` which used low-opacity
    /// translucent mist — now banned for creating visual noise.
    /// Uses adaptive `cardSurface` (#292a2b dark / #f7f7f7 light).
    func nativeCardStyle() -> some View {
        self
            .padding(AppTheme.spaceMD)   // 17pt
            .background(AppTheme.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous)
                    .stroke(AppTheme.cardBorder, lineWidth: 0.5)
            )
    }

    // MARK: - Glass Card Style (backward-compatible alias)

    /// Alias for `nativeCardStyle()`.  Existing call sites continue to
    /// work but now render the high-opacity native Apple card.
    func glassCardStyle() -> some View {
        nativeCardStyle()
    }

    // MARK: - Primary Action Button (Apple Pill CTA)

    /// Action Blue pill button — `#0066cc` background, white text,
    /// full-pill radius, 11×22pt padding.  The signature Apple CTA.
    func actionButtonStyle() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeBody, weight: .regular))
            .foregroundColor(.white)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .background(
                Capsule().fill(AppTheme.accentAction)
            )
    }

    // MARK: - Header Divider

    /// Adds a crisp 0.5pt bottom hairline to a toolbar/header container.
    func headerDivider() -> some View {
        self.overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 0.5)
        }
    }

    // MARK: - Keycap

    func keycapStyle() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeFine, weight: .medium, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.radiusXS)
                    .fill(.quaternary)
                    .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
            )
    }

    // MARK: - Elegant Toggle

    func elegantToggle() -> some View {
        self
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(AppTheme.toggleTint)
    }

    // MARK: - Liquid Menu (Picker capsule)

    func liquidMenuStyle() -> some View {
        modifier(LiquidMenuModifier())
    }
}

// MARK: - Liquid Menu Modifier

private struct LiquidMenuModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: AppTheme.fontSizeCaption))
            .foregroundColor(AppTheme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isHovered
                        ? Color.primary.opacity(0.12)
                        : Color.primary.opacity(0.06)
                    )
                    .animation(AppTheme.Motion.snip.gated, value: isHovered)
            )
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.down")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
            }
            .onHover { hovering in isHovered = hovering }
    }
}
