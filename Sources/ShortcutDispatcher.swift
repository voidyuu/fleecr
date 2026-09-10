import AppKit
import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("app.openSettings")
    static let toggleSidebar = Notification.Name("app.toggleSidebar")
}

@MainActor
final class ShortcutDispatcher {
    static let shared = ShortcutDispatcher()
    private var monitor: Any?

    func install(model: AppModel) {
        uninstall()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model = model else { return event }

            // Yield keyboard event while recording a new shortcut in settings
            if ShortcutStore.shared.recordingItemID != nil {
                return event
            }

            // Do not intercept plain typing when a text field is focused
            if let responder = NSApp.keyWindow?.firstResponder {
                if responder is NSTextField || (responder is NSTextView && !(responder is LineBreakTerminalView)) {
                    if !event.modifierFlags.contains(.command) {
                        return event
                    }
                }
            }

            guard let actionID = ShortcutStore.shared.actionItemID(for: event) else {
                return event
            }

            if Self.handleAction(actionID, model: model) {
                return nil
            }
            return event
        }
    }

    func uninstall() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    @discardableResult
    private static func handleAction(_ id: String, model: AppModel) -> Bool {
        switch id {
        case "newTerminal":
            model.startNewTerminal()
            return true

        case "newSpace":
            model.createNewSpace()
            return true

        case "closePane":
            // ⌘W only closes the currently selected pane while the main console
            // window is focused. Anywhere else (e.g. the Settings window) it
            // falls through to the default "Close" command so the focused
            // window (Settings) closes instead of a pane in a window you can't
            // even see.
            let mainWindowID = NSUserInterfaceItemIdentifier("fleecr.main")
            if NSApp.keyWindow?.identifier == mainWindowID {
                model.closeCurrentPane()
                return true
            }
            return false

        case "quickSearch":
            model.showSearch = true
            return true

        case "toggleSidebar":
            NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            return true

        case "openSettings":
            NotificationCenter.default.post(name: .openSettings, object: nil)
            AppDelegate.openSettingsWindow()
            return true

        case "increaseFontSize":
            let current = UserDefaults.standard.double(forKey: TerminalDefaults.fontSizeKey)
            let actual = current > 0 ? current : TerminalDefaults.defaultFontSize
            UserDefaults.standard.set(min(36, actual + 1), forKey: TerminalDefaults.fontSizeKey)
            return true

        case "decreaseFontSize":
            let current = UserDefaults.standard.double(forKey: TerminalDefaults.fontSizeKey)
            let actual = current > 0 ? current : TerminalDefaults.defaultFontSize
            UserDefaults.standard.set(max(8, actual - 1), forKey: TerminalDefaults.fontSizeKey)
            return true

        case "resetFontSize":
            UserDefaults.standard.set(TerminalDefaults.defaultFontSize, forKey: TerminalDefaults.fontSizeKey)
            return true

        default:
            return false
        }
    }
}
