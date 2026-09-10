import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

// MARK: - Key Combination

public struct KeyCombination: Equatable, Hashable, Codable {
    public var keyCode: UInt16
    public var modifiers: UInt
    public var keyDisplay: String

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyDisplay: String? = nil) {
        self.keyCode = keyCode
        let relevant = modifiers.intersection([.command, .shift, .option, .control])
        self.modifiers = UInt(relevant.rawValue)
        if let keyDisplay = keyDisplay {
            self.keyDisplay = keyDisplay
        } else {
            self.keyDisplay = Self.displayString(for: keyCode, characters: nil)
        }
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifiers))
    }

    public var modifierSymbols: String {
        Self.modifierSymbols(for: modifierFlags)
    }

    public var displayString: String {
        modifierSymbols + keyDisplay
    }

    public func matches(event: NSEvent) -> Bool {
        let relevant = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard relevant.rawValue == modifierFlags.rawValue else { return false }
        if event.keyCode == keyCode { return true }
        if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
            if chars == keyDisplay.lowercased() { return true }
        }
        return false
    }

    public static func modifierSymbols(for flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    public static func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control,
             kVK_RightShift, kVK_RightOption, kVK_RightControl, kVK_Function:
            return true
        default:
            return false
        }
    }

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
             kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return true
        default:
            return false
        }
    }

    public static func displayString(for keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        default:
            if let chars = characters, !chars.isEmpty {
                return chars.uppercased()
            }
            return "?"
        }
    }

    public var swiftUIKeyEquivalent: KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_Return: return .return
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_Escape: return .escape
        case kVK_Delete: return .delete
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_Home: return .home
        case kVK_End: return .end
        default:
            if let first = keyDisplay.lowercased().first {
                return KeyEquivalent(first)
            }
            return nil
        }
    }

    public var swiftUIEventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        let flags = modifierFlags
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

// MARK: - Shortcut Category

public enum ShortcutCategory: String, CaseIterable, Identifiable, Codable {
    case all = "all"
    case general = "general"
    case terminal = "terminal"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:
            return String(localized: "shortcut.category.all", defaultValue: "All")
        case .general:
            return String(localized: "shortcut.category.general", defaultValue: "General")
        case .terminal:
            return String(localized: "shortcut.category.terminal", defaultValue: "Terminal")
        }
    }

    public var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .general: return "gearshape"
        case .terminal: return "terminal"
        }
    }
}

// MARK: - Shortcut Item

public struct ShortcutItem: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let category: ShortcutCategory
    public let icon: String
    public let defaultShortcut: KeyCombination?
    public let description: String?

    public init(
        id: String,
        name: String,
        category: ShortcutCategory,
        icon: String = "command",
        defaultShortcut: KeyCombination?,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.icon = icon
        self.defaultShortcut = defaultShortcut
        self.description = description
    }
}

extension ShortcutItem {
    public static let defaultItems: [ShortcutItem] = [
        // General
        ShortcutItem(
            id: "quickSearch",
            name: String(localized: "shortcut.action.quickSearch", defaultValue: "Quick Search"),
            category: .general,
            icon: "magnifyingglass",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command], keyDisplay: "K"),
            description: String(localized: "shortcut.desc.quickSearch", defaultValue: "Focus the toolbar search bar")
        ),
        ShortcutItem(
            id: "toggleSidebar",
            name: String(localized: "shortcut.action.toggleSidebar", defaultValue: "Toggle Sidebar"),
            category: .general,
            icon: "sidebar.left",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command], keyDisplay: "B"),
            description: String(localized: "shortcut.desc.toggleSidebar", defaultValue: "Show or hide the workspace sidebar")
        ),
        ShortcutItem(
            id: "nextTab",
            name: String(localized: "shortcut.action.nextTab", defaultValue: "Next Tab"),
            category: .general,
            icon: "arrow.right.to.line",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_Tab), modifiers: [.control], keyDisplay: "⇥"),
            description: String(localized: "shortcut.desc.nextTab", defaultValue: "Switch to next agent or terminal tab")
        ),
        ShortcutItem(
            id: "previousTab",
            name: String(localized: "shortcut.action.previousTab", defaultValue: "Previous Tab"),
            category: .general,
            icon: "arrow.left.to.line",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_Tab), modifiers: [.control, .shift], keyDisplay: "⇥"),
            description: String(localized: "shortcut.desc.previousTab", defaultValue: "Switch to previous agent or terminal tab")
        ),
        ShortcutItem(
            id: "newTerminal",
            name: String(localized: "shortcut.action.newTerminal", defaultValue: "New Terminal"),
            category: .general,
            icon: "plus.rectangle.on.rectangle",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command], keyDisplay: "T"),
            description: String(localized: "shortcut.desc.newTerminal", defaultValue: "Start a new terminal session")
        ),
        ShortcutItem(
            id: "newSpace",
            name: String(localized: "shortcut.action.newSpace", defaultValue: "New Space"),
            category: .general,
            icon: "folder.badge.plus",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command], keyDisplay: "N"),
            description: String(localized: "shortcut.desc.newSpace", defaultValue: "Create a new workspace space")
        ),
        ShortcutItem(
            id: "closePane",
            name: String(localized: "shortcut.action.closePane", defaultValue: "Close Current Pane"),
            category: .general,
            icon: "xmark.square",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command], keyDisplay: "W"),
            description: String(localized: "shortcut.desc.closePane", defaultValue: "Close the currently selected terminal or agent")
        ),
        ShortcutItem(
            id: "openSettings",
            name: String(localized: "shortcut.action.openSettings", defaultValue: "Preferences"),
            category: .general,
            icon: "gearshape",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_Comma), modifiers: [.command], keyDisplay: ","),
            description: String(localized: "shortcut.desc.openSettings", defaultValue: "Open application preferences")
        ),

        // Terminal
        ShortcutItem(
            id: "increaseFontSize",
            name: String(localized: "shortcut.action.increaseFontSize", defaultValue: "Increase Font Size"),
            category: .terminal,
            icon: "plus.magnifyingglass",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_Equal), modifiers: [.command], keyDisplay: "+"),
            description: String(localized: "shortcut.desc.increaseFontSize", defaultValue: "Make terminal font larger")
        ),
        ShortcutItem(
            id: "decreaseFontSize",
            name: String(localized: "shortcut.action.decreaseFontSize", defaultValue: "Decrease Font Size"),
            category: .terminal,
            icon: "minus.magnifyingglass",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_Minus), modifiers: [.command], keyDisplay: "-"),
            description: String(localized: "shortcut.desc.decreaseFontSize", defaultValue: "Make terminal font smaller")
        ),
        ShortcutItem(
            id: "resetFontSize",
            name: String(localized: "shortcut.action.resetFontSize", defaultValue: "Reset Font Size"),
            category: .terminal,
            icon: "arrow.counterclockwise",
            defaultShortcut: KeyCombination(keyCode: UInt16(kVK_ANSI_0), modifiers: [.command], keyDisplay: "0"),
            description: String(localized: "shortcut.desc.resetFontSize", defaultValue: "Restore default terminal font size")
        ),
    ]
}

// MARK: - Binding State

public enum BindingState: Codable, Equatable {
    case unassigned
    case custom(KeyCombination)
}

// MARK: - Shortcut Store

@MainActor
public final class ShortcutStore: ObservableObject {
    public static let shared = ShortcutStore()
    private static let defaultsKey = "app.shortcuts.bindings"

    @Published public private(set) var items: [ShortcutItem]
    @Published public private(set) var bindings: [String: BindingState] = [:]
    @Published public var recordingItemID: String? = nil
    @Published public var liveModifiers: NSEvent.ModifierFlags = []
    @Published public var validationError: String? = nil

    private let defaults: UserDefaults
    private var monitor: Any?

    public init(items: [ShortcutItem] = ShortcutItem.defaultItems, defaults: UserDefaults = .standard) {
        self.items = items
        self.defaults = defaults
        loadBindings()
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func loadBindings() {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: BindingState].self, from: data) {
            self.bindings = saved
        }
    }

    private func saveBindings() {
        if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public func shortcut(for item: ShortcutItem) -> KeyCombination? {
        shortcut(forItemID: item.id)
    }

    public func shortcut(forItemID id: String) -> KeyCombination? {
        if let state = bindings[id] {
            switch state {
            case .unassigned:
                return nil
            case .custom(let combination):
                return combination
            }
        }
        return items.first(where: { $0.id == id })?.defaultShortcut
    }

    public func setShortcut(_ shortcut: KeyCombination?, for item: ShortcutItem) {
        setShortcut(shortcut, forItemID: item.id)
    }

    public func setShortcut(_ shortcut: KeyCombination?, forItemID id: String) {
        if let shortcut = shortcut {
            bindings[id] = .custom(shortcut)
        } else {
            bindings[id] = .unassigned
        }
        saveBindings()
    }

    public func resetToDefault(for item: ShortcutItem) {
        bindings.removeValue(forKey: item.id)
        saveBindings()
    }

    public func resetAll() {
        bindings.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    public func isDefault(for item: ShortcutItem) -> Bool {
        guard let state = bindings[item.id] else { return true }
        switch state {
        case .unassigned:
            return item.defaultShortcut == nil
        case .custom(let combination):
            return item.defaultShortcut == combination
        }
    }

    public func conflicts(for item: ShortcutItem) -> [ShortcutItem] {
        guard let current = shortcut(for: item) else { return [] }
        return items.filter { other in
            other.id != item.id && shortcut(for: other) == current
        }
    }

    public func hasConflict(for item: ShortcutItem) -> Bool {
        !conflicts(for: item).isEmpty
    }

    public func actionItemID(for event: NSEvent) -> String? {
        for item in items {
            if let combo = shortcut(for: item), combo.matches(event: event) {
                return item.id
            }
        }
        return nil
    }

    // MARK: - Recording Interaction

    public func startRecording(for item: ShortcutItem) {
        recordingItemID = item.id
        liveModifiers = []
        validationError = nil
        installMonitor()
    }

    public func stopRecording() {
        recordingItemID = nil
        liveModifiers = []
        validationError = nil
        removeMonitor()
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self = self, let currentID = self.recordingItemID else { return event }

            switch event.type {
            case .leftMouseDown:
                self.stopRecording()
                return event

            case .flagsChanged:
                let relevant = event.modifierFlags.intersection([.command, .shift, .option, .control])
                self.liveModifiers = relevant
                return nil

            case .keyDown:
                let keyCode = event.keyCode

                // 1. Esc -> cancel
                if keyCode == UInt16(kVK_Escape) {
                    self.stopRecording()
                    return nil
                }

                // 2. Delete / ForwardDelete without modifiers -> clear shortcut
                let relevantModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if (keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete)) && relevantModifiers.isEmpty {
                    self.setShortcut(nil, forItemID: currentID)
                    self.stopRecording()
                    return nil
                }

                // 3. Modifier key alone down -> ignore
                if KeyCombination.isModifierKey(keyCode) {
                    return nil
                }

                // 4. Validate combination
                let isFn = KeyCombination.isFunctionKey(keyCode)
                let isTab = keyCode == UInt16(kVK_Tab)
                let hasCmdOptCtrl = relevantModifiers.contains(.command) || relevantModifiers.contains(.option) || relevantModifiers.contains(.control)

                if isFn || isTab || hasCmdOptCtrl {
                    let display = KeyCombination.displayString(for: keyCode, characters: event.charactersIgnoringModifiers)
                    let comb = KeyCombination(keyCode: keyCode, modifiers: relevantModifiers, keyDisplay: display)
                    self.setShortcut(comb, forItemID: currentID)
                    self.stopRecording()
                    return nil
                } else {
                    NSSound.beep()
                    self.validationError = String(localized: "shortcut.error.modifierRequired", defaultValue: "Include ⌘, ⌥, or ⌃")
                    return nil
                }

            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
