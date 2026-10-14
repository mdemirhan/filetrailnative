// Port of apps/desktop/src/renderer/lib/theme.ts, hooks/useWindowAppearance.ts and applyNativeAppearance in main.ts
import AppKit
import FTFoundation

/// The look the app is painted in: the palette of the effective appearance and the colors derived from the accent.
public struct Theme: Equatable, Sendable {
    public let appearance: ThemeAppearance
    public let accentHex: String
    public let palette: ThemePalette
    public let accent: AccentPalette

    public init(appearance: ThemeAppearance, accentHex: String) {
        self.appearance = appearance
        self.accentHex = accentHex
        palette = ThemePalette.palette(for: appearance)
        accent = AccentPalette(hex: accentHex, appearance: appearance)
    }

    public var isDark: Bool { appearance == .dark }

    /// The color behind a window that is not an explorer window, shown before its views paint and while it resizes
    /// (`windowBackgroundColor`).
    public var pageWindowBackground: RGBA {
        isDark ? RGBA(r: 0x16, g: 0x16, b: 0x18) : RGBA(r: 0xf4, g: 0xf5, b: 0xf8)
    }
}

/// What a selected row is painted with (F-932, `windowActivity.ts`).
public struct SelectionColors: Equatable, Sendable {
    public var background: RGBA
    public var text: RGBA
    /// For the secondary cells of a row.
    public var secondaryText: RGBA
}

extension Theme {
    /// A selection is the accent with white text in the focused pane of the active window. In an unfocused pane, and
    /// everywhere while the window is in the background, it is `--bg-active-inactive` with the ordinary text.
    public func selection(paneFocused: Bool, windowActive: Bool) -> SelectionColors {
        if paneFocused && windowActive {
            return SelectionColors(
                background: accent.selectionBg, text: accent.onSelection, secondaryText: accent.onSelectionSoft)
        }
        return SelectionColors(
            background: palette.bgActiveInactive, text: palette.textPrimary, secondaryText: palette.textSecondary)
    }
}

/// Holds the current theme for the whole app and tells everything that draws with it when it changes. The theme is
/// the preference (Auto, Light or Dark), or for Auto the macOS appearance, followed live; the accent is any hex color.
/// Nothing here uses `controlAccentColor` or the system selection highlight (PLAN.md section 3.5).
@MainActor
public final class AppearanceModel {
    /// The one the app's windows use.
    public static let shared = AppearanceModel()

    public private(set) var preference: ThemePreference
    public private(set) var accentHex: String
    public private(set) var theme: Theme

    /// Whether macOS is in its dark appearance: asked again each time Auto needs it.
    private let systemPrefersDark: @MainActor () -> Bool
    /// Applies Light, Dark or Auto to the app's native parts (title bars, scroll bars, pickers).
    private let setNativeAppearance: @MainActor (ThemePreference) -> Void
    private var observers: [UUID: @MainActor (Theme) -> Void] = [:]
    private var pageWindows: [WeakWindow] = []
    private var systemObservation: NSKeyValueObservation?

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    public init(
        theme: ThemePreference = .auto, accent: String = AppPreferenceLimits.defaultAccent,
        systemPrefersDark: @escaping @MainActor () -> Bool = AppearanceModel.macOSIsDark,
        setNativeAppearance: @escaping @MainActor (ThemePreference) -> Void = AppearanceModel.setAppAppearance
    ) {
        self.systemPrefersDark = systemPrefersDark
        self.setNativeAppearance = setNativeAppearance
        preference = theme
        let hex = AppPreferenceLimits.normalizeAccentColor(accent) ?? AppPreferenceLimits.defaultAccent
        accentHex = hex
        self.theme = Theme(
            appearance: Self.effective(theme, systemDark: systemPrefersDark()), accentHex: hex)
    }

    // MARK: Changing the look

    /// A new theme and accent (either may be nil to keep it): the native parts follow, windows other than explorer
    /// windows get their background, and everything that observes is told once, only when the look changed.
    public func apply(theme newTheme: ThemePreference? = nil, accent newAccent: String? = nil) {
        let nextPreference = newTheme ?? preference
        let nextAccent = newAccent.flatMap(AppPreferenceLimits.normalizeAccentColor) ?? accentHex
        if nextPreference != preference {
            preference = nextPreference
            setNativeAppearance(nextPreference)
        }
        accentHex = nextAccent
        refresh()
    }

    /// The theme and accent of the app's preferences.
    public func apply(_ preferences: AppPreferences) {
        apply(theme: preferences.theme, accent: preferences.accent)
    }

    /// A preference change from the channel: only the theme and the accent matter here.
    public func preferencesChanged(_ preferences: AppPreferences, _ change: PreferencesChange) {
        guard change.patch["theme"] != nil || change.patch["accent"] != nil else { return }
        apply(preferences)
    }

    /// macOS changed between light and dark: while the preference is Auto the look follows.
    public func systemAppearanceChanged() {
        guard preference == .auto else { return }
        refresh()
    }

    /// Follows the macOS appearance while the app runs (`nativeTheme`'s update event).
    public func startFollowingSystem(_ application: NSApplication = NSApplication.shared) {
        systemObservation = application.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.systemAppearanceChanged() } }
        }
    }

    private func refresh() {
        let next = Theme(
            appearance: Self.effective(preference, systemDark: systemPrefersDark()), accentHex: accentHex)
        applyBackground(next)
        guard next != theme else { return }
        theme = next
        for observer in observers.values { observer(next) }
    }

    // MARK: Observing

    /// Calls `handler` with each new theme until the returned token is released or cancelled.
    public func observe(_ handler: @escaping @MainActor (Theme) -> Void) -> Observation {
        let id = UUID()
        observers[id] = handler
        return Observation { [weak self] in self?.observers[id] = nil }
    }

    /// Ends an observation when released.
    @MainActor
    public final class Observation {
        private var onCancel: (@MainActor () -> Void)?

        fileprivate init(_ onCancel: @escaping @MainActor () -> Void) {
            self.onCancel = onCancel
        }

        public func cancel() {
            onCancel?()
            onCancel = nil
        }

        isolated deinit { cancel() }
    }

    // MARK: Windows other than explorer windows

    /// A window that is not an explorer window (Settings, Help, About, Acknowledgements) gets the theme's background;
    /// explorer windows stay transparent, as a color would cover their sidebar material.
    public func register(pageWindow window: NSWindow) {
        pageWindows.removeAll { $0.window == nil || $0.window === window }
        pageWindows.append(WeakWindow(window: window))
        window.backgroundColor = NSColor(theme.pageWindowBackground)
    }

    private func applyBackground(_ theme: Theme) {
        pageWindows.removeAll { $0.window == nil }
        for entry in pageWindows { entry.window?.backgroundColor = NSColor(theme.pageWindowBackground) }
    }

    // MARK: The look painted

    /// `resolveEffectiveTheme`.
    static func effective(_ preference: ThemePreference, systemDark: Bool) -> ThemeAppearance {
        AppPreferenceLimits.resolveEffectiveTheme(preference, systemPrefersDark: systemDark) == .dark ? .dark : .light
    }

    /// Native parts follow the app's theme rather than macOS: Light or Dark pins them, Auto follows the system.
    public static func setAppAppearance(_ theme: ThemePreference) {
        switch theme {
        case .auto: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Whether macOS is in dark mode, whatever the app pins its own windows to.
    public static func macOSIsDark() -> Bool {
        // With the app following the system its own appearance says so, and is current as soon as macOS switches.
        if NSApplication.shared.appearance == nil {
            return NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }
}
