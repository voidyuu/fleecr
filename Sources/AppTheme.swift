import AppKit
import SwiftUI

/// A selectable terminal color scheme: background/foreground/selection/cursor plus
/// a 16-color ANSI table. `ThemeStore` pairs each appearance mode (dark or light)
/// with its own theme, so the terminal palette is always consistent with the
/// chrome, whose look is driven by the chosen appearance mode (via `Theme.*`
/// appearance-adaptive tokens).
enum AppTheme: String, CaseIterable, Identifiable {
    case terminalDark
    case terminalLight
    case afterglow
    case alabaster
    case gruvbox
    case dracula

    var id: String { rawValue }

    /// Whether this palette belongs in dark mode or light mode. The terminal only
    /// accepts a theme whose `isDark` matches the live appearance.
    var isDark: Bool {
        switch self {
        case .terminalDark, .afterglow, .gruvbox, .dracula: true
        case .terminalLight, .alabaster: false
        }
    }

    var displayName: String {
        switch self {
        case .terminalDark: String(localized: "theme.terminalDark", defaultValue: "Terminal Dark")
        case .terminalLight: String(localized: "theme.terminalLight", defaultValue: "Terminal Light")
        case .afterglow: String(localized: "theme.afterglow", defaultValue: "Afterglow")
        case .alabaster: String(localized: "theme.alabaster", defaultValue: "Alabaster")
        case .gruvbox: String(localized: "theme.gruvbox", defaultValue: "Gruvbox")
        case .dracula: String(localized: "theme.dracula", defaultValue: "Dracula")
        }
    }

    /// The theme's own accent (used for the swatch / preview foreground).
    var background: String {
        switch self {
        case .terminalDark: "#101012"
        case .terminalLight: "#ffffff"
        case .afterglow: "#212121"
        case .alabaster: "#f7f7f7"
        case .gruvbox: "#282828"
        case .dracula: "#282a36"
        }
    }

    var foreground: String {
        switch self {
        case .terminalDark: "#d6d6d6"
        case .terminalLight: "#3a3a3a"
        case .afterglow: "#d0d0d0"
        case .alabaster: "#000000"
        case .gruvbox: "#ebdbb2"
        case .dracula: "#f8f8f2"
        }
    }

    var selection: String {
        switch self {
        case .terminalDark: "#2b2f38"
        case .terminalLight: "#c3d0e0"
        case .afterglow: "#303030"
        case .alabaster: "#c9d0d9"
        case .gruvbox: "#504945"
        case .dracula: "#44475a"
        }
    }

    var cursor: String {
        switch self {
        case .terminalDark: "#d6d6d6"
        case .terminalLight: "#3a3a3a"
        case .afterglow: "#d0d0d0"
        case .alabaster: "#007acc"
        case .gruvbox: "#ebdbb2"
        case .dracula: "#f8f8f2"
        }
    }

    /// The 16-color ANSI table (indices 0–7 normal, 8–15 bright).
    var ansi: [String] {
        switch self {
        case .terminalDark: TerminalDefaults.darkHexPalette
        case .terminalLight: TerminalDefaults.lightHexPalette
        case .afterglow: Self.afterglowAnsi
        case .alabaster: Self.alabasterAnsi
        case .gruvbox: Self.gruvboxAnsi
        case .dracula: Self.draculaAnsi
        }
    }

    /// Themes suitable for true-dark mode.
    static let darkThemes: [AppTheme] = allCases.filter(\.isDark)
    /// Themes suitable for true light mode.
    static let lightThemes: [AppTheme] = allCases.filter { !$0.isDark }

    // MARK: - Theme palettes

    private static let afterglowAnsi: [String] = [
        "#151515", "#ac4142", "#7e8e50", "#e4b567",
        "#6c99bb", "#9f4e86", "#7dd5cf", "#d0d0d0",
        "#505050", "#ac4142", "#7e8e50", "#e4b567",
        "#6c99bb", "#9f4e86", "#7dd5cf", "#f5f5f5",
    ]

    private static let alabasterAnsi: [String] = [
        "#000000", "#aa3731", "#448c27", "#cb8800", "#325cc0", "#7a3e9d", "#0083b2", "#f7f7f7",
        "#777777", "#f03e31", "#60cb00", "#ffbc5d", "#007acc", "#e64ce6", "#00aacb", "#f7f7f7",
    ]

    private static let gruvboxAnsi: [String] = [
        "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
        "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
    ]

    private static let draculaAnsi: [String] = [
        "#282a36", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
        "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
    ]
}

/// The app's overall appearance (drives `NSApp.appearance` and therefore every
/// `Theme.*` token: sidebar, titlebar, chrome).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "theme.system", defaultValue: "System")
        case .light: String(localized: "theme.light", defaultValue: "Light")
        case .dark: String(localized: "theme.dark", defaultValue: "Dark")
        }
    }
    var isDark: Bool {
        switch self {
        case .system: false
        case .light: false
        case .dark: true
        }
    }
}

/// Holds the active appearance mode plus one terminal theme per mode, so dark
/// mode and light mode can each use a different theme while the chrome follows
/// the appearance mode. Persists all three choices.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let appearanceKey = "app.theme"
    static let darkThemeKey = "terminal.theme.dark"
    static let lightThemeKey = "terminal.theme.light"

    @Published private(set) var appearance: AppearanceMode
    @Published private(set) var darkTheme: AppTheme
    @Published private(set) var lightTheme: AppTheme

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceKey),
           let mode = AppearanceMode(rawValue: raw) {
            appearance = mode
        } else {
            appearance = .system
        }

        if let raw = UserDefaults.standard.string(forKey: Self.darkThemeKey),
           let theme = AppTheme(rawValue: raw), theme.isDark {
            darkTheme = theme
        } else {
            darkTheme = .terminalDark
        }

        if let raw = UserDefaults.standard.string(forKey: Self.lightThemeKey),
           let theme = AppTheme(rawValue: raw), !theme.isDark {
            lightTheme = theme
        } else {
            lightTheme = .alabaster
        }
        Self.applyAppearance()
    }

    /// The terminal palette to use right now, chosen by the live appearance.
    var activeTheme: AppTheme { isDark ? darkTheme : lightTheme }

    /// Whether the app is effectively in dark mode right now.
    var isDark: Bool {
        switch appearance {
        case .dark: return true
        case .light: return false
        case .system:
            guard let app = NSApp else { return false }
            return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard mode != appearance else { return }
        appearance = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.appearanceKey)
        Self.applyAppearance()
    }

    /// Sets the theme used by dark or light mode (a light mode only accepts light
    /// themes and vice versa, so the palettes always match the chrome).
    func setTheme(_ theme: AppTheme, forDark: Bool) {
        if forDark, theme.isDark {
            darkTheme = theme
            UserDefaults.standard.set(theme.rawValue, forKey: Self.darkThemeKey)
        } else if !forDark, !theme.isDark {
            lightTheme = theme
            UserDefaults.standard.set(theme.rawValue, forKey: Self.lightThemeKey)
        }
    }

    /// Re-applies the persisted appearance at launch (idempotent).
    func restoreAppearance() {
        Self.applyAppearance()
    }

    private static func applyAppearance() {
        // `NSApp` is nil very early (e.g. the unit-test host), so guard it — it
        // is an implicitly-unwrapped optional.
        guard let app = NSApp else { return }
        switch shared.appearance {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Hex color convenience (used by the theme picker preview)

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}