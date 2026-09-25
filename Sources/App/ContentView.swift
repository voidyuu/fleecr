import HerdrKit
import SwiftUI
import AppKit

struct RootView: View {
    @Environment(\.openSettings) private var openSettings
    // Owned by AppDelegate so it outlives the window — see AppDelegate in FleecrApp.swift.
    @ObservedObject var model: AppModel
    // Deliberately not persisted: the app always launches with the sidebar visible.
    @State private var sidebarCollapsed = false
    // Shared by the sidebar's inline filter (⌘K) and the toolbar search field.
    @State private var searchQuery = ""

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AppKitSplitView(
                sidebarCollapsed: $sidebarCollapsed,
                sidebar: AnyView(SidebarView(model: model, query: $searchQuery)),
                detail: AnyView(DetailView(model: model, query: $searchQuery)),
                createSpace: {
                    guard let space = model.currentSpace, let device = model.device(space.deviceID) else { return }
                    model.createNewSpace(on: device)
                }
            )
            .ignoresSafeArea(edges: .top)
        }
        .background(
            Button("") { sidebarCollapsed.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { model.showSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { model.startNewTerminal() }
                .keyboardShortcut("t", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
        )
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            sidebarCollapsed.toggle()
        }
        .focusedSceneValue(\.appModel, model)
        .background(WindowAccessor { window in
            // Distinctive identifier so shortcut handling can tell the main
            // console window apart from e.g. the Settings window.
            window?.identifier = NSUserInterfaceItemIdentifier("fleecr.main")
            window?.titlebarAppearsTransparent = true
            window?.styleMask.insert(.fullSizeContentView)
        })
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 980, minHeight: 620)
        .onAppear {
            model.start()
            ShortcutDispatcher.shared.install(model: model)
        }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet(model: model) }
        .sheet(item: $model.spaceToRename) { entry in renameSpaceSheet(model: model, entry: entry) }
        .sheet(item: $model.agentToRename) { entry in renameAgentSheet(model: model, entry: entry) }
        .sheet(item: $model.terminalToRename) { entry in renameTerminalSheet(model: model, entry: entry) }
        .sheet(item: $model.deviceToEdit) { device in EditDeviceSheet(model: model, device: device) }
        .sheet(item: $model.sshAuthenticationRequest) { request in
            SSHAuthenticationSheet(model: model, request: request)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

}

/// Height of the native unified toolbar band; the sidebar toggle matches it.
enum TitlebarMetrics {
    static let height: CGFloat = 54
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    // Search query shared with the sidebar filter. The toolbar search field writes
    // here; SidebarView reads the same value to filter its rows in place.
    @Binding var query: String
    @State private var searchFieldFocused = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeStore = ThemeStore.shared

    private var activeTerminalTheme: AppTheme {
        let isDark: Bool
        switch themeStore.appearance {
        case .system: isDark = colorScheme == .dark
        case .light: isDark = false
        case .dark: isDark = true
        }
        return isDark ? themeStore.darkTheme : themeStore.lightTheme
    }

    private var terminalBackground: Color {
        Color(hex: activeTerminalTheme.background)
    }

    var body: some View {
        detailContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground.ignoresSafeArea())
        // AppKit owns the terminal and search toolbar items so + and search remain adjacent.
        .background(
            NativeToolbarBridge(
                model: model,
                query: $query,
                isSearchPresented: $searchFieldFocused
            )
        )
        // ⌘K (hidden button + global shortcut) asks the model to open search;
        // focus toggling lives here next to the field state it drives.
        .onChange(of: model.showSearch) { _, requested in
            guard requested else { return }
            model.showSearch = false
            searchFieldFocused.toggle()
        }
        // Losing focus (Esc, ⌘K again, clicking a terminal) clears the filter and
        // resets the bar to its placeholder, like a fresh Spotlight open.
        .onChange(of: searchFieldFocused) { _, focused in
            if !focused {
                query = ""
            }
        }
    }

    private var detailContent: some View {
        terminal.clipped()
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var terminalThinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var terminalFontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var terminalLineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage(TerminalDefaults.mouseReportingKey) private var terminalMouseReporting = TerminalDefaults.defaultMouseReporting
    /// The attach target whose process exited, and how. The key includes the entry,
    /// target ID, and server version so a stale exit never covers a live terminal.
    @State private var endedAttachKey: String?
    @State private var endedAttachCode: Int32?
    @State private var attachRetry = 0
    @State private var uploadingAttachment = false

    @ViewBuilder
    private var terminal: some View {
        attachedTerminal
    }

    @ViewBuilder
    private var attachedTerminal: some View {
        if let entry = model.selectedAttachedEntry {
            let serverVersion = model.serverVersion(deviceID: entry.device.id)
            let targetIdentity: String = {
                switch entry.attachTarget {
                case .agent(let paneID): return "agent-\(paneID)"
                case .terminal(let terminalID): return "terminal-\(terminalID)"
                }
            }()
            let attachKey = "\(entry.id)-\(targetIdentity)-\(serverVersion ?? "unknown")"
            let attachmentCapabilities: AgentAttachmentCapabilities? = {
                guard case .agent(let agentEntry) = entry else { return nil }
                return model.attachmentCapabilities(
                    deviceID: agentEntry.device.id,
                    agentKind: agentEntry.agent.agentKindRaw
                )
            }()
            ZStack {
                AttachTerminalView(
                    device: entry.device,
                    target: entry.attachTarget,
                    serverVersion: serverVersion,
                    attachmentCapabilities: attachmentCapabilities,
                    fontName: terminalFontName,
                    fontSize: terminalFontSize,
                    thinStrokes: terminalThinStrokes,
                    fontWeight: terminalFontWeight,
                    lineSpacing: terminalLineSpacing,
                    theme: activeTerminalTheme,
                    mouseReporting: terminalMouseReporting,
                    onAttachmentError: { model.actionError = $0 },
                    onAttachmentUploadingChanged: { uploadingAttachment = $0 },
                    onExit: { code in
                        endedAttachKey = attachKey
                        endedAttachCode = code
                    }
                )
                .id("attach-\(attachKey)-\(attachRetry)")
                if endedAttachKey == attachKey {
                    attachEndedOverlay(entry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(terminalBackground)
            .overlay(alignment: .bottomTrailing) {
                if uploadingAttachment { uploadIndicator }
            }
            .onChange(of: attachKey) { _, _ in
                endedAttachKey = nil
                uploadingAttachment = false
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textGhost)
                Text(placeholderText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                if model.hasReconnectableDevice {
                    Button("Reconnect") {
                        model.reconnectFailedDevices()
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(terminalBackground)
        }
    }

    /// ssh exits 255 for transport failures; everything else is the far end closing
    /// (takeover by another client, the pane going away, herdr stopping).
    private func attachEndedOverlay(_ entry: AppModel.AttachedEntry) -> some View {
        let dropped = endedAttachCode == 255
        return VStack(spacing: 10) {
            Image(systemName: dropped ? "bolt.horizontal.circle" : "rectangle.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textGhost)
            Text(dropped ? String(localized: "Connection to \(entry.device.name) dropped") : String(localized: "Terminal session ended"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(dropped
                ? String(localized: "The SSH connection behind this terminal went away.")
                : String(localized: "Another client took this pane over, or the attach closed."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Button("Reconnect") {
                endedAttachKey = nil
                attachRetry += 1
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground.opacity(0.94))
    }

    private var uploadIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Uploading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 20)
        .padding(.bottom, 18)
    }

    private var placeholderText: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        default:
            if model.selectedSpace != nil
                && model.visibleAgents.isEmpty
                && model.visibleTerminals.isEmpty {
                return String(localized: "No agents or terminals in this space yet")
            }
            return String(localized: "Select an agent or terminal, or start a new one")
        }
    }

}
