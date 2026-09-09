import AppKit
import SwiftUI

/// Owns the window toolbar with AppKit rather than asking SwiftUI to merge a
/// `.searchable` item with independently placed toolbar actions. The order is
/// exact: leading controls, one flexible space, New Terminal, then the native
/// `NSSearchToolbarItem`. Therefore + and search are adjacent, with no hidden
/// SwiftUI placement region between them.
struct NativeToolbarBridge: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @Binding var sidebarCollapsed: Bool
    @Binding var query: String
    @Binding var isSearchPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.install(on: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.install(on: nsView.window)
        context.coordinator.syncSearchState()
    }

    @MainActor
    final class Coordinator: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
        private enum ID {
            static let toolbar = NSToolbar.Identifier("fleecr.toolbar")
            static let sidebar = NSToolbarItem.Identifier("fleecr.sidebar")
            static let space = NSToolbarItem.Identifier("fleecr.new-space")
            static let terminal = NSToolbarItem.Identifier("fleecr.new-terminal")
            static let search = NSToolbarItem.Identifier("fleecr.search")
        }

        var parent: NativeToolbarBridge
        private weak var installedWindow: NSWindow?
        private var searchItem: NSSearchToolbarItem?
        private var returnGuard: Any?
        /// 0.3s debounce so the sidebar filter isn't recomputed on every keystroke;
        /// it only updates after typing pauses for a moment.
        private static let searchDebounce: TimeInterval = 0.3
        private var debounceTask: Task<Void, Never>?

        init(_ parent: NativeToolbarBridge) { self.parent = parent }

        func install(on window: NSWindow?) {
            guard let window, installedWindow !== window else { return }
            let toolbar = NSToolbar(identifier: ID.toolbar)
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            window.toolbar = toolbar
            installedWindow = window
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [ID.sidebar, ID.space, .flexibleSpace, ID.terminal, ID.search]
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            // The flexible space is deliberately before +, never between + and search.
            [ID.sidebar, ID.space, .flexibleSpace, ID.terminal, ID.search]
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            switch itemIdentifier {
            case ID.sidebar:
                return buttonItem(ID.sidebar, image: "sidebar.left", label: "Toggle sidebar", action: #selector(toggleSidebar))
            case ID.space:
                return buttonItem(ID.space, image: "folder.badge.plus", label: "New Space", action: #selector(newSpace))
            case ID.terminal:
                return buttonItem(ID.terminal, image: "plus", label: "New Terminal", action: #selector(newTerminal))
            case ID.search:
                let item = NSSearchToolbarItem(itemIdentifier: ID.search)
                let field = NSSearchField()
                field.placeholderString = "Search agents, terminals, and spaces…"
                field.font = .systemFont(ofSize: 13)
                field.delegate = self
                // Deliberately NO target/action on the field itself. NSSearchField
                // fires the action on EVERY keystroke (`sendsSearchStringImmediately`),
                // which would submit/clear the search as soon as the user types the
                // first character. Live filtering is driven by controlTextDidChange;
                // submit is driven by the Return key monitor below instead.
                field.target = nil
                field.action = nil
                item.searchField = field
                item.preferredWidthForSearchField = 320
                searchItem = item
                return item
            default:
                return nil
            }
        }

        private func buttonItem(
            _ identifier: NSToolbarItem.Identifier,
            image: String,
            label: String,
            action: Selector
        ) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: image, accessibilityDescription: label)
            item.target = self
            item.action = action
            return item
        }

        func syncSearchState() {
            guard let field = searchItem?.searchField else { return }
            // Never clobber the field while it's the active editor. Programmatically
            // setting stringValue over an in-progress IME composition (Chinese/Japanese
            // pinyin) destroys the marked text, so typing with an input method
            // fails. During editing the field is the source of truth; only push
            // an external value in (e.g. clearing on blur) when it isn't being edited.
            let isEditing = field.currentEditor() != nil && field.window?.firstResponder === field.currentEditor()
            if !isEditing, field.stringValue != parent.query {
                field.stringValue = parent.query
            }
            if parent.isSearchPresented, field.window?.firstResponder !== field.currentEditor() {
                searchItem?.beginSearchInteraction()
            }
        }

        @objc private func toggleSidebar() { parent.sidebarCollapsed.toggle() }
        @objc private func newTerminal() { parent.model.startNewTerminal() }
        @objc private func newSpace() {
            guard let space = parent.model.currentSpace, let device = parent.model.device(space.deviceID) else { return }
            parent.model.createNewSpace(on: device)
        }
        private func submitSearch() {
            // Enter commits: clears the field and drops focus (the filter releases
            // back to the full list). Not reached while an IME is composing — the
            // return guard swallows that Return so it commits text instead.
            guard let field = searchItem?.searchField else { return }
            parent.query = ""
            parent.isSearchPresented = false
            field.window?.makeFirstResponder(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            // Debounce: buffer keystrokes, applying the query only after the user
            // pauses. A pending update is cancelled and restarted on each keystroke.
            debounceTask?.cancel()
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.searchDebounce * 1_000_000_000))
                guard let self else { return }
                self.parent.query = field.stringValue
            }
        }
        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isSearchPresented = true
            installReturnGuard()
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isSearchPresented = false
            removeReturnGuard()
            // Drop any pending update: leaving the field clears the search, and a
            // stale debounce firing afterwards would re-filter with the old text.
            debounceTask?.cancel()
            debounceTask = nil
        }

        // Enter handling lives in a local key monitor rather than the field's own
        // action. With a Chinese/Japanese/Korean input method, Return is what
        // "commits the pinyin candidate into the field". When there is an
        // in-progress composition (marked text), that Return must go to the input
        // method — never trigger a submit. When there is no composition, Return is
        // the ordinary "commit/dismiss the search" key. The monitor is armed only
        // while this field is the active editor, so it affects nothing else.
        private func installReturnGuard() {
            guard returnGuard == nil else { return }
            let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Only act while the search field itself is the active editor.
                guard let field = self.searchItem?.searchField,
                      field.window?.firstResponder === field.currentEditor(),
                      let editor = field.currentEditor() as? NSTextView
                else { return event }
                let isEnter = event.keyCode == 36 || event.keyCode == 76 // Return / keypad-Enter
                if editor.hasMarkedText() {
                    // A CJK input method is composing: Return commits the candidate
                    // into the field, so hand it to the IME and never submit.
                    if isEnter {
                        editor.interpretKeyEvents([event])
                        return nil
                    }
                    return event
                }
                if isEnter {
                    // Real Return = commit/dismiss the search.
                    self.submitSearch()
                    return nil
                }
                return event
            }
            returnGuard = token
        }

        private func removeReturnGuard() {
            if let token = returnGuard {
                NSEvent.removeMonitor(token)
                returnGuard = nil
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.query = ""
                parent.isSearchPresented = false
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}