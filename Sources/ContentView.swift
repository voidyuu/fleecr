import HerdrKit
import SwiftUI

struct RootView: View {
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
                DetailView(model: model, sidebarCollapsed: $sidebarCollapsed)
            }
            .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)

            // In-window device panel; NSPopover throws in ViewBridge on macOS 26+ betas.
            if model.showDevicePanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { model.showDevicePanel = false }
                DevicePopover(model: model, isPresented: $model.showDevicePanel)
                    .padding(.leading, 10)
                    .padding(.bottom, 46)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                    .background(
                        Button("") { model.showDevicePanel = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    )
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.showDevicePanel)
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
        .focusedSceneValue(\.appModel, model)
        .focusedSceneValue(\.splitAxis, model.shellSplitAxis)
        .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 620)
        .onAppear { model.start() }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet(model: model) }
        .sheet(isPresented: $model.showNewTerminal) { NewTerminalSheet(model: model) }
        .sheet(item: $model.spaceToRename) { entry in RenameSpaceSheet(model: model, entry: entry) }
        .sheet(item: $model.agentToRename) { entry in RenameAgentSheet(model: model, entry: entry) }
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
}

/// Titlebar metrics: 28pt matches the system traffic-light centerline (14pt) exactly.
enum TitlebarMetrics {
    static let height: CGFloat = 28
    static let trafficLightClearance: CGFloat = 78
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    @Binding var sidebarCollapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            titlebar
                .background(Theme.contentBackground)
                .zIndex(1)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            detailContent
                // Losing the selected agent tears the SplitContainer down without
                // resetting the axis, which would leave the same phantom split.
                //
                // Load-bearing beyond that: this is the ONLY thing that clears the axis
                // when the agent goes away. `dismantleNSView` nils the coordinator's
                // onExit before killing the shell, so the shell's own onExit never fires
                // on teardown. Remove this and "split open with no agent selected"
                // becomes reachable, which is a state a deferred focus request can be
                // armed into with nothing left in the tree to consume it.
                .onChange(of: model.selectedAttachedEntry?.id) { _, id in
                    if id == nil { model.shellSplitAxis = nil }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground.ignoresSafeArea())
    }

    private var detailContent: some View {
        terminal.clipped()
    }

    // MARK: - Titlebar strip (28pt, traditional)

    private var titlebar: some View {
        HStack(spacing: 8) {
            if sidebarCollapsed {
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - 10)
                TitlebarIconButton(systemName: "sidebar.left", help: "Show Sidebar (⌘B)") {
                    sidebarCollapsed = false
                }
            }
            if let attached = model.selectedAttachedEntry {
                switch attached {
                case .agent(let entry):
                    let agent = entry.agent
                    statusGlyph(agent.status)
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help((agent.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                    Spacer(minLength: 12)
                    AgentKindBadge(kind: agent.agent)
                    Text("\u{b7}")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textGhost)
                    Text(model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if model.showsRowDeviceBadges {
                        DeviceChip(device: entry.device)
                    }
                    statusPill(agent.status)
                case .terminal(let entry):
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help((entry.pane.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                    Spacer(minLength: 12)
                    Text(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if model.showsRowDeviceBadges {
                        DeviceChip(device: entry.device)
                    }
                }
            } else {
                Text("No terminal selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
        }
        .padding(.leading, sidebarCollapsed ? 10 : 14)
        .padding(.trailing, 12)
        .frame(height: TitlebarMetrics.height)
    }

    @ViewBuilder
    private func statusGlyph(_ status: AgentStatus) -> some View {
        switch status {
        case .working:
            SpinnerView(color: Theme.working).frame(width: 13, height: 13)
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            EmptyView()
        case .idle, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusPill(_ status: AgentStatus) -> some View {
        let label: String? = {
            switch status {
            case .working: return String(localized: "Working")
            case .blocked: return String(localized: "Needs input")
            case .done: return String(localized: "Done")
            case .idle, .unknown: return nil
            }
        }()
        if let label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.statusColor(status))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Theme.statusColor(status).opacity(0.13), in: Capsule())
        }
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var terminalThinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var terminalFontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var terminalLineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage(TerminalDefaults.mouseReportingKey) private var terminalMouseReporting = TerminalDefaults.defaultMouseReporting
    @Environment(\.colorScheme) private var colorScheme
    /// The entry whose attach process exited, and how. Keyed by entry id so a stale
    /// exit from a previously selected pane never covers a live terminal.
    @State private var endedAttachKey: String?
    @State private var endedAttachCode: Int32?
    @State private var attachRetry = 0
    @State private var uploadingAttachment = false
    @State private var splitTracker = SplitFocusTracker()

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
            SplitContainer(
                axis: model.shellSplitAxis,
                activeSide: model.activeSplitSide,
                ratio: $model.splitRatio
            ) {
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
                        dark: colorScheme == .dark,
                        mouseReporting: terminalMouseReporting,
                        onAttachmentError: { model.actionError = $0 },
                        onAttachmentUploadingChanged: { uploadingAttachment = $0 },
                        onExit: { code in
                            endedAttachKey = entry.id
                            endedAttachCode = code
                        },
                        onViewReady: {
                            splitTracker.agentView = $0
                            model.splitAgentView = $0
                        }
                    )
                        .id("attach-\(entry.id)-\(colorScheme)-\(attachRetry)")
                    if endedAttachKey == entry.id {
                        attachEndedOverlay(entry)
                    }
                }
            } second: {
                ShellTerminalView(
                    fontName: terminalFontName,
                    fontSize: terminalFontSize,
                    thinStrokes: terminalThinStrokes,
                    fontWeight: terminalFontWeight,
                    lineSpacing: terminalLineSpacing,
                    dark: colorScheme == .dark,
                    mouseReporting: terminalMouseReporting,
                    onExit: { _ in model.shellSplitAxis = nil },
                    onViewReady: {
                        splitTracker.shellView = $0
                        model.splitShellView = $0
                    }
                )
                    // Deliberately not keyed on colorScheme like the attach above:
                    // a new id tears the view down and kills the shell with whatever
                    // was running in it, and unlike a herdr pane a local shell has no
                    // server-side state to reattach to. updateNSView re-themes it.
                    .id("shell")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
            .overlay(alignment: .bottomTrailing) {
                if uploadingAttachment { uploadIndicator }
            }
            .onAppear {
                // Single source of truth: the tracker writes straight into the model
                // instead of holding its own copy for a second onChange to mirror.
                splitTracker.onSideChanged = { model.activeSplitSide = $0 }
                splitTracker.start()
            }
            .onChange(of: entry.id) { _, _ in
                endedAttachKey = nil
                uploadingAttachment = false
                if model.shellSplitAxis != nil { focusTerminal(model.splitAgentView) }
            }
            // Keyed on the window becoming key rather than on a delay: that is the event
            // that follows the sheet's responder restore. Filtered to the terminal's own
            // window and consumed no matter which window it was, so a pending request can
            // never survive to a later, unrelated activation — coming back from ⌘Tab or
            // closing Settings would otherwise yank the keyboard into a live pane.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard model.pendingSplitAgentFocus else { return }
                model.pendingSplitAgentFocus = false
                guard let window = note.object as? NSWindow,
                      window === model.splitAgentView?.window
                else { return }
                focusTerminal(model.splitAgentView)
            }
            // Splitting moves the keyboard to the shell, so closing the split has to
            // hand it back — by ⌘W or by the shell exiting on its own. Reset the
            // tracked side to the agent so the next split starts predictably.
            .onChange(of: model.shellSplitAxis) { _, axis in
                if axis == nil {
                    model.activeSplitSide = .agent
                    model.pendingSplitAgentFocus = false
                    focusRemainingTerminal()
                }
            }
        } else {
            // The .onReceive below only exists on the branch above, so a request armed
            // while no pane is selected would have no consumer and would be cashed in by
            // some later activation. Revealing a pane that has since gone away lands here.
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
            .onAppear { model.pendingSplitAgentFocus = false }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: String(localized: "Add Device"),
                subtitle: String(localized: "Uses OpenSSH config, agent, Tailscale SSH, or password")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("mac-studio", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("vincent@10.10.10.87", text: $target)
                    .textFieldStyle(.roundedBorder)
                Text("user@host, a ~/.ssh/config alias, or user@host:port for a custom port.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Device") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    model.addDevice(
                        name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                        sshTarget: trimmedTarget
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
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

struct NewTerminalSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = Device.local.id
    @State private var workspaceID = ""

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    private var spaces: [WorkspaceInfo] {
        model.session(deviceID).workspaces
    }

    private var spaceLabel: String {
        spaces.first { $0.workspaceID == workspaceID }?.label ?? String(localized: "a Herdr space")
    }

    private var subtitle: String {
        return String(localized: "Creates a persistent shell in \(spaceLabel) on \(chosenDevice.name)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "terminal",
                title: String(localized: "New Terminal"),
                subtitle: subtitle
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                if model.showsDeviceBadges {
                    SheetSectionLabel("DEVICE")
                    Picker("", selection: $deviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: deviceID) { _, _ in
                        workspaceID = spaces.first?.workspaceID ?? ""
                    }

                    Spacer().frame(height: 8)
                }

                SheetSectionLabel("SPACE")
                Picker("", selection: $workspaceID) {
                    ForEach(spaces) { workspace in
                        Text(workspace.label).tag(workspace.workspaceID)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Terminal") {
                    model.startNewTerminal(device: chosenDevice, workspaceID: workspaceID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(workspaceID.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .onAppear {
            deviceID = model.selectedSpace?.deviceID
                ?? model.selectedAttachedEntry?.device.id
                ?? model.deviceFilter
                ?? model.devices.first?.id
                ?? Device.local.id
            let preferredSpace = model.selectedSpace?.deviceID == deviceID
                ? model.selectedSpace?.workspaceID
                : model.selectedAttachedEntry.flatMap {
                    $0.device.id == deviceID ? $0.workspaceID : nil
                }
            workspaceID = preferredSpace.flatMap { preferred in
                spaces.contains { $0.workspaceID == preferred } ? preferred : nil
            } ?? spaces.first?.workspaceID ?? ""
        }
    }
}

struct RenameSpaceSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.SpaceEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Space"),
                subtitle: String(localized: "Rename \(entry.workspace.label) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Space name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.renameSpace(entry, label: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == entry.workspace.label)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { name = entry.workspace.label }
    }
}

struct RenameAgentSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.AgentEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Agent"),
                subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Agent name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Chinese, spaces, and punctuation are allowed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.renameAgent(entry, name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == entry.title)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { name = entry.title }
    }
}

struct EditDeviceSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Edit Device"),
                subtitle: String(localized: "Changing the SSH target reconnects the device")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("SSH target", text: $target)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    model.updateDevice(
                        device.id,
                        name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                        sshTarget: trimmedTarget
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear {
            name = device.name
            target = device.sshTarget ?? ""
        }
    }
}
