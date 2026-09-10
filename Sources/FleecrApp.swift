import AppKit
import Darwin
import HerdrKit
import SwiftUI
import UserNotifications

/// Holds app termination open long enough to tear the SSH tunnels down: without
/// `.terminateLater` the process dies before the teardown task gets to run, and the
/// `ssh` children survive with PPID 1 along with their sockets.
///
/// The delegate owns the model rather than borrowing it from the window: closing the
/// last window (⌘W) would otherwise drop the only strong reference, and the quit that
/// follows would find nothing left to tear down.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.shutdownAllSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    static func openSettingsWindow() {
        if let menu = NSApp.mainMenu {
            for item in menu.items {
                if let sub = item.submenu {
                    for (index, subItem) in sub.items.enumerated() {
                        if subItem.keyEquivalent == "," {
                            sub.performActionForItem(at: index)
                            if let action = subItem.action {
                                NSApp.sendAction(action, to: subItem.target, from: subItem)
                            }
                            return
                        }
                    }
                }
            }
        }
    }
}

private struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }
}

@main
struct FleecrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(\.appModel) private var focusedModel

    init() {
        if ProcessInfo.processInfo.environment[SSHCredentialStore.askPassModeEnvironmentKey] == "1" {
            Self.runSSHAskPass()
        }
        AppLanguage.synchronize()
        SSHCredentialStore.purgeAuthorizations()
        TerminalDefaults.registerBundledFonts()
        // Force the store early so the persisted theme's appearance lands before
        // the first window draws.
        let _ = ThemeStore.shared
        ThemeStore.shared.restoreAppearance()
    }

    private var activeModel: AppModel {
        focusedModel ?? appDelegate.model
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: appDelegate.model)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // fleecr is a single-window console, so New Window is not available.
            CommandGroup(replacing: .newItem) {
                let model = activeModel
                Button("New Terminal") { model.startNewTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
                if model.devices.count == 1, let device = model.devices.first {
                    Button("New Space") { model.createNewSpace(on: device) }
                        .keyboardShortcut("n", modifiers: .command)
                } else {
                    Menu("New Space") {
                        ForEach(model.devices) { device in
                            Button(device.name) { model.createNewSpace(on: device) }
                        }
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }

            CommandGroup(replacing: .saveItem) {
                Button("Close") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }

    private static func runSSHAskPass() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let rawID = environment[SSHCredentialStore.authorizationIDEnvironmentKey],
              let authorizationID = UUID(uuidString: rawID),
              let password = try? SSHCredentialStore.consumePassword(authorizationID: authorizationID)
        else {
            Darwin.exit(EXIT_FAILURE)
        }
        FileHandle.standardOutput.write(Data("\(password)\n".utf8))
        Darwin.exit(EXIT_SUCCESS)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            DevicesSettingsView(model: model)
                .tabItem { Label(String(localized: "Devices", defaultValue: "Devices"), systemImage: "server.rack") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

struct TerminalSettingsView: View {
    @AppStorage(TerminalDefaults.fontNameKey) private var fontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var thinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var fontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var lineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage(TerminalDefaults.mouseReportingKey) private var mouseReporting = TerminalDefaults.defaultMouseReporting
    @ObservedObject private var themeStore = ThemeStore.shared

    private let families = TerminalDefaults.monospacedFamilies()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Font", selection: $fontName) {
                    Text("System Mono (SF Mono)").tag("")
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Slider(value: $fontSize, in: 9...22, step: 0.5) {
                        Text("Size")
                    }
                    Text(String(format: "%.1f pt", fontSize))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    Stepper("", value: $fontSize, in: 9...22, step: 0.5)
                        .labelsHidden()
                }

                Picker("Weight", selection: $fontWeight) {
                    Text(String(localized: "font.weight.light", defaultValue: "Light"))
                        .tag(Double(NSFont.Weight.light.rawValue))
                    Text(String(localized: "font.weight.regular", defaultValue: "Regular"))
                        .tag(TerminalDefaults.defaultFontWeight)
                    Text(String(localized: "font.weight.medium", defaultValue: "Medium"))
                        .tag(Double(NSFont.Weight.medium.rawValue))
                }
                .pickerStyle(.segmented)
                .disabled(!fontName.isEmpty)
                .help("Only the system monospaced font has selectable weights.")

                HStack {
                    Slider(value: $lineSpacing, in: 1.0...1.4, step: 0.05) {
                        Text("Line spacing")
                    }
                    Text(String(format: "%.0f%%", lineSpacing * 100))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Toggle(isOn: $thinStrokes) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Thin strokes")
                        Text("Turns off macOS font smoothing, which thickens glyph stems and makes agent output — Claude Code's bold text especially — look heavy and smudged.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $mouseReporting) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mouse reporting")
                        Text("Forwards clicks and drags to TUI apps that ask for them. Turn off to always select text with the mouse — Shift-drag selects either way.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button("Reset to Defaults") {
                    fontName = ""
                    fontSize = TerminalDefaults.defaultFontSize
                    fontWeight = TerminalDefaults.defaultFontWeight
                    lineSpacing = TerminalDefaults.defaultLineSpacing
                    thinStrokes = true
                    mouseReporting = TerminalDefaults.defaultMouseReporting
                }
            }

            // Outside the Form: its two-column layout has no label for these
            // rows and would indent them by the whole label column.
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("❯ herdr agent attach w1:p1 — 中文 ABC 0123")
                    .font(Font(TerminalDefaults.font(name: fontName, size: fontSize, weight: fontWeight)))
                    .foregroundStyle(Color(hex: themeStore.activeTheme.foreground))
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: themeStore.activeTheme.background), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject private var store = ThemeStore.shared
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: appearanceSelection) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("System follows the system setting. The selected mode colors the sidebar and chrome.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("Dark Mode Theme", selection: darkThemeSelection) {
                ForEach(AppTheme.darkThemes) { theme in
                    themeLabel(theme).tag(theme)
                }
            }

            Picker("Light Mode Theme", selection: lightThemeSelection) {
                ForEach(AppTheme.lightThemes) { theme in
                    themeLabel(theme).tag(theme)
                }
            }
            Text("Each mode keeps its own terminal theme, so the palette always matches the app.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            themePreview

            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(verbatim: option.displayName).tag(option.rawValue)
                }
            }
            .onChange(of: language) { _, newValue in
                AppLanguage.apply(AppLanguage(rawValue: newValue) ?? .system)
            }
            // Changing AppleLanguages only takes effect on the next process start.
            Text("Changing language takes effect after you quit and reopen fleecr.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var appearanceSelection: Binding<AppearanceMode> {
        Binding(
            get: { store.appearance },
            set: { store.setAppearance($0) }
        )
    }

    private var darkThemeSelection: Binding<AppTheme> {
        Binding(
            get: { store.darkTheme },
            set: { store.setTheme($0, forDark: true) }
        )
    }

    private var lightThemeSelection: Binding<AppTheme> {
        Binding(
            get: { store.lightTheme },
            set: { store.setTheme($0, forDark: false) }
        )
    }

    private func themeLabel(_ theme: AppTheme) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: theme.background))
                .frame(width: 26, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Theme.sidebarBorder, lineWidth: 1)
                )
            Text(verbatim: theme.displayName)
        }
    }

    /// A small live preview of the active terminal palette.
    private var themePreview: some View {
        let theme = store.activeTheme
        return VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("❯ herdr agent attach w1:p1 — herdr ABC 0123")
                    .font(Font(TerminalDefaults.font(name: "", size: 12.5)))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ForEach(Array(theme.ansi.prefix(8)), id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: hex))
                            .frame(width: 18, height: 12)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: theme.background), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(hex: theme.foreground), lineWidth: 1)
            )
        }
    }
}


struct NotificationSettingsView: View {
    @AppStorage("notifications.enabled") private var enabled = true
    @AppStorage("notifications.sound") private var sound = true
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Form {
            Toggle("Notify when an agent finishes or needs input", isOn: $enabled)
            Toggle("Play a sound", isOn: $sound)
            Text("Finished agents only notify while you're not watching them — herdr reports panes you have open as idle, not done.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            switch authorization {
            case .denied:
                HStack(spacing: 8) {
                    Text("Notifications are disabled in System Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            case .notDetermined:
                HStack(spacing: 8) {
                    Text("Notification permission hasn't been granted yet.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Request Permission") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                            refreshAuthorization()
                        }
                    }
                    .controlSize(.small)
                }
            case .authorized, .provisional:
                Text("Notification permission granted.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(20)
        .onAppear { refreshAuthorization() }
    }

    private func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { authorization = settings.authorizationStatus }
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Text("fleecr — a native macOS console for herdr.")
                .font(.system(size: 12.5))
            Text(String(localized: "Devices are managed from the Devices tab in Settings.", defaultValue: "Devices are managed from the Devices tab in Settings."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
