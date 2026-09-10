import AppKit
import SwiftUI

/// A selectable terminal color scheme: background/foreground/selection/cursor plus
/// a 16-color ANSI table. `ThemeStore` pairs each appearance mode (dark or light)
/// with its own theme, so the terminal palette is always consistent with the
/// chrome, whose look is driven by the chosen appearance mode (via `Theme.*`
/// appearance-adaptive tokens).
enum AppTheme: String, CaseIterable, Identifiable {
    // Dark themes
    case terminalDark
    case tokyoNight
    case catppuccinMocha
    case nord
    case gruvbox
    case dracula
    case solarizedDark
    case oneDark
    case githubDark
    case monokaiPro
    case rosePine
    case afterglow

    // Light themes
    case terminalLight
    case tokyoNightDay
    case catppuccinLatte
    case nordLight
    case gruvboxLight
    case solarizedLight
    case githubLight
    case rosePineDawn
    case alabaster

    var id: String { rawValue }

    /// Whether this palette belongs in dark mode or light mode. The terminal only
    /// accepts a theme whose `isDark` matches the live appearance.
    var isDark: Bool {
        switch self {
        case .terminalDark, .tokyoNight, .catppuccinMocha, .nord,
             .gruvbox, .dracula, .solarizedDark, .oneDark,
             .githubDark, .monokaiPro, .rosePine, .afterglow:
            true
        case .terminalLight, .tokyoNightDay, .catppuccinLatte, .nordLight,
             .gruvboxLight, .solarizedLight, .githubLight, .rosePineDawn,
             .alabaster:
            false
        }
    }

    var displayName: String {
        switch self {
        case .terminalDark: "Terminal Dark"
        case .tokyoNight: "Tokyo Night"
        case .catppuccinMocha: "Catppuccin Mocha"
        case .nord: "Nord"
        case .gruvbox: "Gruvbox"
        case .dracula: "Dracula"
        case .solarizedDark: "Solarized Dark"
        case .oneDark: "One Dark"
        case .githubDark: "GitHub Dark"
        case .monokaiPro: "Monokai Pro"
        case .rosePine: "Rose Pine"
        case .afterglow: "Afterglow"

        case .terminalLight: "Terminal Light"
        case .tokyoNightDay: "Tokyo Night Day"
        case .catppuccinLatte: "Catppuccin Latte"
        case .nordLight: "Nord Light"
        case .gruvboxLight: "Gruvbox Light"
        case .solarizedLight: "Solarized Light"
        case .githubLight: "GitHub Light"
        case .rosePineDawn: "Rose Pine Dawn"
        case .alabaster: "Alabaster"
        }
    }

    /// The theme's own accent (used for the swatch / preview foreground).
    var background: String {
        switch self {
        case .terminalDark: "#101012"
        case .tokyoNight: "#1a1b26"
        case .catppuccinMocha: "#1e1e2e"
        case .nord: "#2e3440"
        case .gruvbox: "#282828"
        case .dracula: "#282a36"
        case .solarizedDark: "#002b36"
        case .oneDark: "#21252b"
        case .githubDark: "#0d1117"
        case .monokaiPro: "#2d2a2e"
        case .rosePine: "#191724"
        case .afterglow: "#212121"

        case .terminalLight: "#ffffff"
        case .tokyoNightDay: "#e1e2e7"
        case .catppuccinLatte: "#eff1f5"
        case .nordLight: "#e5e9f0"
        case .gruvboxLight: "#fbf1c7"
        case .solarizedLight: "#fdf6e3"
        case .githubLight: "#ffffff"
        case .rosePineDawn: "#faf4ed"
        case .alabaster: "#f7f7f7"
        }
    }

    var foreground: String {
        switch self {
        case .terminalDark: "#d6d6d6"
        case .tokyoNight: "#c0caf5"
        case .catppuccinMocha: "#cdd6f4"
        case .nord: "#d8dee9"
        case .gruvbox: "#ebdbb2"
        case .dracula: "#f8f8f2"
        case .solarizedDark: "#839496"
        case .oneDark: "#abb2bf"
        case .githubDark: "#e6edf3"
        case .monokaiPro: "#fcfcfa"
        case .rosePine: "#e0def4"
        case .afterglow: "#d0d0d0"

        case .terminalLight: "#3a3a3a"
        case .tokyoNightDay: "#3760bf"
        case .catppuccinLatte: "#4c4f69"
        case .nordLight: "#414858"
        case .gruvboxLight: "#3c3836"
        case .solarizedLight: "#657b83"
        case .githubLight: "#1f2328"
        case .rosePineDawn: "#575279"
        case .alabaster: "#000000"
        }
    }

    var selection: String {
        switch self {
        case .terminalDark: "#2b2f38"
        case .tokyoNight: "#33467c"
        case .catppuccinMocha: "#585b70"
        case .nord: "#434c5e"
        case .gruvbox: "#504945"
        case .dracula: "#44475a"
        case .solarizedDark: "#073642"
        case .oneDark: "#323844"
        case .githubDark: "#26354a"
        case .monokaiPro: "#5b595c"
        case .rosePine: "#403d52"
        case .afterglow: "#303030"

        case .terminalLight: "#c3d0e0"
        case .tokyoNightDay: "#99a7df"
        case .catppuccinLatte: "#dc8a78"
        case .nordLight: "#d8dee9"
        case .gruvboxLight: "#ebdbb2"
        case .solarizedLight: "#eee8d5"
        case .githubLight: "#b6e3ff"
        case .rosePineDawn: "#dfdad9"
        case .alabaster: "#c9d0d9"
        }
    }

    var selectionForeground: String? {
        switch self {
        case .tokyoNight: "#c0caf5"
        case .tokyoNightDay: "#3760bf"
        case .catppuccinMocha: "#cdd6f4"
        case .catppuccinLatte: "#eff1f5"
        case .nord: "#eceff4"
        case .nordLight: "#4c556a"
        case .gruvboxLight: "#3c3836"
        case .solarizedDark: "#93a1a1"
        case .solarizedLight: "#586e75"
        case .oneDark: "#abb2bf"
        case .githubDark: "#ffffff"
        case .githubLight: "#1f2328"
        case .monokaiPro: "#fcfcfa"
        case .rosePine: "#e0def4"
        case .rosePineDawn: "#575279"
        default: nil
        }
    }

    var cursor: String {
        switch self {
        case .terminalDark: "#d6d6d6"
        case .tokyoNight: "#c0caf5"
        case .catppuccinMocha: "#f5e0dc"
        case .nord: "#eceff4"
        case .gruvbox: "#ebdbb2"
        case .dracula: "#f8f8f2"
        case .solarizedDark: "#839496"
        case .oneDark: "#abb2bf"
        case .githubDark: "#2f81f7"
        case .monokaiPro: "#c1c0c0"
        case .rosePine: "#e0def4"
        case .afterglow: "#d0d0d0"

        case .terminalLight: "#3a3a3a"
        case .tokyoNightDay: "#3760bf"
        case .catppuccinLatte: "#dc8a78"
        case .nordLight: "#7bb3c3"
        case .gruvboxLight: "#3c3836"
        case .solarizedLight: "#657b83"
        case .githubLight: "#0969da"
        case .rosePineDawn: "#575279"
        case .alabaster: "#007acc"
        }
    }

    /// The 16-color ANSI table (indices 0–7 normal, 8–15 bright).
    var ansi: [String] {
        switch self {
        case .terminalDark: TerminalDefaults.darkHexPalette
        case .tokyoNight: Self.tokyoNightAnsi
        case .catppuccinMocha: Self.catppuccinMochaAnsi
        case .nord: Self.nordAnsi
        case .gruvbox: Self.gruvboxAnsi
        case .dracula: Self.draculaAnsi
        case .solarizedDark: Self.solarizedDarkAnsi
        case .oneDark: Self.oneDarkAnsi
        case .githubDark: Self.githubDarkAnsi
        case .monokaiPro: Self.monokaiProAnsi
        case .rosePine: Self.rosePineAnsi
        case .afterglow: Self.afterglowAnsi

        case .terminalLight: TerminalDefaults.lightHexPalette
        case .tokyoNightDay: Self.tokyoNightDayAnsi
        case .catppuccinLatte: Self.catppuccinLatteAnsi
        case .nordLight: Self.nordLightAnsi
        case .gruvboxLight: Self.gruvboxLightAnsi
        case .solarizedLight: Self.solarizedLightAnsi
        case .githubLight: Self.githubLightAnsi
        case .rosePineDawn: Self.rosePineDawnAnsi
        case .alabaster: Self.alabasterAnsi
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

    private static let gruvboxLightAnsi: [String] = [
        "#fbf1c7", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#7c6f64",
        "#928374", "#9d0006", "#79740e", "#b57614", "#076678", "#8f3f71", "#427b58", "#3c3836",
    ]

    private static let draculaAnsi: [String] = [
        "#282a36", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
        "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
    ]

    private static let tokyoNightAnsi: [String] = [
        "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
        "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
    ]

    private static let tokyoNightDayAnsi: [String] = [
        "#e9e9ed", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#6172b0",
        "#a1a6c5", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#3760bf",
    ]

    private static let catppuccinMochaAnsi: [String] = [
        "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
        "#585b70", "#f7aec2", "#c2ecbf", "#fcd682", "#aeccfc", "#f398da", "#b1eae1", "#a6adc8",
    ]

    private static let catppuccinLatteAnsi: [String] = [
        "#bcc0cc", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#5c5f77",
        "#acb0be", "#e7103f", "#46b02f", "#e49931", "#3878f6", "#ef95d7", "#19a1a8", "#6c6f85",
    ]

    private static let nordAnsi: [String] = [
        "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
        "#596377", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
    ]

    private static let nordLightAnsi: [String] = [
        "#3b4252", "#bf616a", "#96b17f", "#c5a565", "#81a1c1", "#b48ead", "#7bb3c3", "#a5abb6",
        "#4c566a", "#bf616a", "#96b17f", "#c5a565", "#81a1c1", "#b48ead", "#82afae", "#eceff4",
    ]

    private static let solarizedDarkAnsi: [String] = [
        "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
        "#335e69", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
    ]

    private static let solarizedLightAnsi: [String] = [
        "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#bbb5a2",
        "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
    ]

    private static let oneDarkAnsi: [String] = [
        "#21252b", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
        "#767676", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
    ]

    private static let githubDarkAnsi: [String] = [
        "#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
        "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#ffffff",
    ]

    private static let githubLightAnsi: [String] = [
        "#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
        "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f",
    ]

    private static let monokaiProAnsi: [String] = [
        "#2d2a2e", "#ff6188", "#a9dc76", "#ffd866", "#fc9867", "#ab9df2", "#78dce8", "#fcfcfa",
        "#727072", "#ff6188", "#a9dc76", "#ffd866", "#fc9867", "#ab9df2", "#78dce8", "#fcfcfa",
    ]

    private static let rosePineAnsi: [String] = [
        "#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
        "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
    ]

    private static let rosePineDawnAnsi: [String] = [
        "#f2e9e1", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279",
        "#9893a5", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279",
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