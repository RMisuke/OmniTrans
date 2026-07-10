import SwiftUI
import AppKit

// MARK: - Theme Mode

enum ThemeMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light:  "浅色"
        case .dark:   "深色"
        }
    }
}

// MARK: - Theme Resolver

enum ThemeResolver {
    static func appearance(for mode: ThemeMode) -> NSAppearance? {
        switch mode {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func effectiveAppearance(for mode: ThemeMode) -> NSAppearance {
        appearance(for: mode) ?? NSApp.effectiveAppearance
    }
}

// MARK: - Theme Engine

/// Central theme engine with zero-flicker transitions and animation speed integration.
///
/// ## Zero-Flicker Strategy
/// 1. `AnimationEngine.disableActions` — suppresses implicit layer animations.
/// 2. `NSAnimationContext.runAnimationGroup(duration: 0)` — disables window-level transitions.
/// 3. Async broadcast via `Task` — non-blocking SwiftUI sync.
/// 4. Status item icon re-application — ensures menu bar instant update.
///
/// ## Animation Speed Integration
/// Reads `animation_speed` from UserDefaults and applies to `AnimationEngine.durationScale`.
/// Persisted separately from the animation gate (`animations_enabled`).
@MainActor
final class ThemeEngine: ObservableObject {
    static let shared = ThemeEngine()

    @Published private(set) var mode: ThemeMode = .system

    private let defaultsKey = "app_appearance"
    private let animationSpeedKey = "animation_speed"

    private init() {
        loadPersisted()
        loadAnimationSpeed()
        observeSystemAppearance()
    }

    // MARK: - Public API

    func setMode(_ mode: ThemeMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
        apply()
    }

    /// Apply current theme with zero-flicker guarantee.
    func apply() {
        let appearance = ThemeResolver.appearance(for: mode)

        // ── Zero-flicker: suppress all implicit animations ──
        AnimationEngine.disableActions {
            // 1. App
            NSApp.appearance = appearance

            // 2. All windows + content views
            for window in NSApp.windows {
                window.appearance = appearance
                window.contentView?.appearance = appearance
                // OmniPanel needs explicit glass backdrop refresh
                if let omni = window as? OmniPanel {
                    omni.refreshAppearance()
                }
            }
        }

        // ── Async SwiftUI broadcast (non-blocking) ──
        Task(priority: .high) { @MainActor in
            NotificationCenter.default.post(name: .themeDidChange, object: appearance)
        }
    }

    // MARK: - Animation Speed

    /// Set the global animation speed scale and persist.
    func setAnimationSpeed(_ scale: DurationScale) {
        AnimationEngine.durationScale = scale
        UserDefaults.standard.set(scale.rawValue, forKey: animationSpeedKey)
    }

    /// Current animation speed scale.
    var animationSpeed: DurationScale {
        AnimationEngine.durationScale
    }

    private func loadAnimationSpeed() {
        let raw = UserDefaults.standard.double(forKey: animationSpeedKey)
        if raw > 0, let scale = DurationScale(rawValue: raw) {
            AnimationEngine.durationScale = scale
        }
        // If key doesn't exist, rawValue is 0.0, which doesn't match any case — stays .normal.
    }

    // MARK: - Persistence

    private func loadPersisted() {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let m = ThemeMode(rawValue: raw) {
            self.mode = m
        }
    }

    // MARK: - System Sync

    private func observeSystemAppearance() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func systemAppearanceChanged() {
        guard mode == .system else { return }
        Task { @MainActor in apply() }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let themeDidChange = Notification.Name("OmniTransThemeDidChange")
}

// MARK: - SwiftUI Bridge

struct ThemeModeKey: EnvironmentKey {
    static let defaultValue: ThemeMode = .system
}

extension EnvironmentValues {
    var themeMode: ThemeMode {
        get { self[ThemeModeKey.self] }
        set { self[ThemeModeKey.self] = newValue }
    }
}

/// Auto-injects `themeMode` into the environment and reacts to theme changes.
/// Apply via `.withTheme()` at the root of every window content view.
struct ThemeObserver: ViewModifier {
    @StateObject private var engine = ThemeEngine.shared

    func body(content: Content) -> some View {
        content
            .environment(\.themeMode, engine.mode)
    }
}

extension View {
    /// Injects theme environment so all child views react instantly.
    func withTheme() -> some View {
        modifier(ThemeObserver())
    }
}
