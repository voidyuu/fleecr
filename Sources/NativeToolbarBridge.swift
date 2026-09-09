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
    @Binding var highlighted: Int
    var resultCount: Int
    var onChoose: () -> Void

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
                field.target = self
                field.action = #selector(submitSearch)
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
            // pinyin) destroys the marked text, so typing with an input method fails.
            // During editing the field is the source of truth; only push an external
            // value in (e.g. clearing on blur) when it isn't being edited.
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
        @objc private func submitSearch() { parent.onChoose() }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.query = field.stringValue
        }
        func controlTextDidBeginEditing(_ obj: Notification) { parent.isSearchPresented = true }
        func controlTextDidEndEditing(_ obj: Notification) { parent.isSearchPresented = false }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.highlighted = min(parent.highlighted + 1, max(parent.resultCount - 1, 0))
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.highlighted = max(parent.highlighted - 1, 0)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.isSearchPresented = false
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}
