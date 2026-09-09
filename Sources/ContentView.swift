import HerdrKit
import SwiftUI
import AppKit

/// Lets us reach the hosting NSWindow to e.g. force a fully transparent title bar
/// (keeps the native toolbar's volume/layout while removing its colour).
struct WindowAccessor: NSViewRepresentable {
    var onUpdate: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onUpdate(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onUpdate(nsView.window) }
    }
}

struct RootView: View {
    @Environment(\.openSettings) private var openSettings
    // Owned by AppDelegate so it outlives the window — see AppDelegate in FleecrApp.swift.
    @ObservedObject var model: AppModel
    // Deliberately not persisted: the app always launches with the sidebar visible.
    @State private var sidebarCollapsed = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                SidebarView(model: model, collapsed: $sidebarCollapsed)
                    .frame(width: sidebarCollapsed ? 0 : 260, alignment: .trailing)
                    .clipped()
                Rectangle()
                    .fill(Theme.sidebarBorder)
                    .frame(width: sidebarCollapsed ? 0 : 1)
                    .ignoresSafeArea()
                DetailView(model: model)
            }
            .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)
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
        .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
        .background(WindowAccessor { window in
            window?.titlebarAppearsTransparent = true
            window?.styleMask.insert(.fullSizeContentView)
        })
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar { toolbarContent }
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
        .alert(
            model.closeRequest?.title ?? "",
            isPresented: Binding(
                get: { model.closeRequest != nil },
                set: { if !$0 { model.closeRequest = nil } }
            )
        ) {
            Button("Close", role: .destructive) {
                model.closeRequest?.perform()
                model.closeRequest = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.closeRequest?.message ?? "")
        }
    }

    /// Extracted so the giant `body` chain stays type-checkable.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                sidebarCollapsed.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle sidebar (⌘B)")
            .accessibilityLabel("Toggle sidebar")
        }
        ToolbarItem(placement: .navigation) {
            Button {
                if let space = model.currentSpace, let device = model.device(space.deviceID) {
                    model.createNewSpace(on: device)
                }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Space")
            .accessibilityLabel("New Space")
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.startNewTerminal()
            } label: {
                Image(systemName: "plus")
            }
            .help("New Terminal (⌘T)")
            .accessibilityLabel("New Terminal")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Search (⌘K)")
            .accessibilityLabel("Search")
        }
    }
}

/// Height of the band the native unified toolbar (52pt) occupies: the detail region reserves
/// it so the terminal never renders under the traffic lights — all toolbar content is native.
enum TitlebarMetrics {
    static let height: CGFloat = 54
}

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            detailContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground.ignoresSafeArea())
    }

    private var detailContent: some View {
        terminal.clipped()
    }

    // MARK: - Toolbar band

    /// Empty band behind the native unified toolbar: reserves its height so the terminal
    /// stays below the traffic lights, and carries the theme background flush to the top
    /// edge. The toolbar's own items (sidebar toggle left, New Terminal right) are native.
    private var titlebar: some View {
        Color(hex: themeStore.activeTheme.background)
            .frame(height: TitlebarMetrics.height)
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var terminalThinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var terminalFontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var terminalLineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage(TerminalDefaults.mouseReportingKey) private var terminalMouseReporting = TerminalDefaults.defaultMouseReporting
    @ObservedObject private var themeStore = ThemeStore.shared
    /// The entry whose attach process exited, and how. Keyed by entry id so a stale
    /// exit from a previously selected pane never covers a live terminal.
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
                    serverVersion: model.serverVersion(deviceID: entry.device.id),
                    attachmentCapabilities: attachmentCapabilities,
                    fontName: terminalFontName,
                    fontSize: terminalFontSize,
                    thinStrokes: terminalThinStrokes,
                    fontWeight: terminalFontWeight,
                    lineSpacing: terminalLineSpacing,
                    theme: themeStore.activeTheme,
                    mouseReporting: terminalMouseReporting,
                    onAttachmentError: { model.actionError = $0 },
                    onAttachmentUploadingChanged: { uploadingAttachment = $0 },
                    onExit: { code in
                        endedAttachKey = entry.id
                        endedAttachCode = code
                    }
                )
                .id("attach-\(entry.id)-\(attachRetry)")
                if endedAttachKey == entry.id {
                    attachEndedOverlay(entry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
            .overlay(alignment: .bottomTrailing) {
                if uploadingAttachment { uploadIndicator }
            }
            .onChange(of: entry.id) { _, _ in
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
            .background(Theme.terminalBackground)
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
        .background(Theme.terminalBackground.opacity(0.94))
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

struct AddDeviceSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var session = "default"
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: String(localized: "Add Device"),
                subtitle: String(localized: "Runs official 'herdr machine add' to prepare and save the machine")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("mac-studio", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("vincent@10.10.10.87", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Text("user@host, a ~/.ssh/config alias, or user@host:port for a custom port.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer().frame(height: 8)
                SheetSectionLabel("REMOTE SESSION")
                TextField("default", text: $session)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Text("Herdr session name on the remote machine (defaults to \"default\").")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting and preparing remote Herdr server…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .font(.system(size: 12))
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Adding…" : "Add Device") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    let trimmedSession = session.trimmingCharacters(in: .whitespaces)
                    isSubmitting = true
                    errorMessage = nil
                    Task {
                        do {
                            try await model.addDevice(
                                name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                                sshTarget: trimmedTarget,
                                session: trimmedSession.isEmpty ? "default" : trimmedSession
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isSubmitting = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
    }
}

struct SSHAuthenticationSheet: View {
    @ObservedObject var model: AppModel
    let request: SSHAuthenticationRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "key.fill",
                title: String(localized: "SSH Authentication"),
                subtitle: request.target
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("PASSWORD")
                SecureField("SSH password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                Label(String(localized: "Saved in your macOS login Keychain"), systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelSSHAuthentication(for: request)
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.saveSSHPassword(password, for: request)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { passwordFocused = true }
    }
}

/// Shared chrome for the app's sheets: icon-badge header, hairline sections, footer actions.
struct SheetHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct SheetSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// One sheet for every rename: it edits the name herdr itself stores (the
/// workspace or tab label), and the rename goes back through herdr's own
/// `workspace.rename` / `tab.rename` — the same RPCs the herdr TUI uses — so
/// herdrm, the herdr TUI, and `herdr api snapshot` all agree on the name.
@MainActor
private func renameSpaceSheet(model: AppModel, entry: AppModel.SpaceEntry) -> some View {
    RenameItemSheet(
        title: String(localized: "Rename Space"),
        subtitle: String(localized: "Rename \(entry.workspace.label) on \(entry.device.name)"),
        placeholder: String(localized: "Space name"),
        hint: nil,
        seed: entry.workspace.label
    ) { name in
        model.renameSpace(entry, label: name)
    }
}

@MainActor
private func renameAgentSheet(model: AppModel, entry: AppModel.AgentEntry) -> some View {
    RenameItemSheet(
        title: String(localized: "Rename Agent"),
        subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)"),
        placeholder: entry.title,
        hint: String(localized: "Chinese, spaces, and punctuation are allowed."),
        seed: entry.tabName
    ) { name in
        model.renameAgent(entry, name: name)
    }
}

@MainActor
private func renameTerminalSheet(model: AppModel, entry: AppModel.TerminalEntry) -> some View {
    RenameItemSheet(
        title: String(localized: "Rename Terminal"),
        subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)"),
        placeholder: entry.title,
        hint: String(localized: "Chinese, spaces, and punctuation are allowed."),
        seed: entry.tab?.renameSeed(agentKind: nil)
    ) { name in
        model.renameTerminal(entry, name: name)
    }
}

/// Edits one backend-owned name. `seed` is the name herdr currently stores;
/// renaming to it is a no-op, so the button disables itself.
struct RenameItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    let title: String
    let subtitle: String
    let placeholder: String
    let hint: String?
    let seed: String?
    let perform: (String) -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(systemImage: "pencil", title: title, subtitle: subtitle)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField(placeholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    perform(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == seed)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { name = seed ?? "" }
    }
}

struct EditDeviceSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var session = "default"
    @State private var isEnabled = true
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Edit Device"),
                subtitle: String(localized: "Applies changes via official 'herdr machine' CLI")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("SSH target", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Spacer().frame(height: 8)
                SheetSectionLabel("REMOTE SESSION")
                TextField("default", text: $session)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Spacer().frame(height: 8)
                Toggle("Enabled", isOn: $isEnabled)
                    .font(.system(size: 12.5))
                    .disabled(isSubmitting)
            }
            .padding(16)

            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying changes via herdr CLI…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .font(.system(size: 12))
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Saving…" : "Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    let trimmedSession = session.trimmingCharacters(in: .whitespaces)
                    isSubmitting = true
                    errorMessage = nil
                    Task {
                        do {
                            try await model.updateDevice(
                                device.id,
                                name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                                sshTarget: trimmedTarget,
                                session: trimmedSession.isEmpty ? "default" : trimmedSession,
                                isEnabled: isEnabled
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isSubmitting = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .onAppear {
            name = device.name
            target = device.sshTarget ?? ""
            session = device.session
            isEnabled = device.isEnabled
        }
    }
}
