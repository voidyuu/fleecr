import Foundation
import HerdrKit
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

/// Global pane identity: pane ids like "w1:p1" collide across devices.
struct PaneRef: Hashable {
    let deviceID: UUID
    let paneID: String
}

struct SpaceRef: Hashable {
    let deviceID: UUID
    let workspaceID: String
}

/// Live state for one device's herdr session.
struct DeviceSessionState {
    var connection: ConnectionState = .idle
    var agents: [AgentInfo] = []
    var workspaces: [WorkspaceInfo] = []
    var tabs: [TabInfo] = []
    var panes: [PaneInfo] = []
    var workspaceCWDs: [String: String] = [:]
    var attachmentCapabilities = AgentAttachmentCapabilityRegistry()
}

struct SSHAuthenticationRequest: Identifiable {
    let deviceID: UUID
    let target: String

    var id: UUID { deviceID }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device]
    @Published var sessions: [UUID: DeviceSessionState] = [:]
    @Published var selectedSpace: SpaceRef?
    @Published var selectedPane: PaneRef? {
        didSet {
            // Leaving a finished agent marks it viewed. Staying on it while
            // the turn ends must not swallow the unread flag.
            if let old = oldValue, old != selectedPane {
                unreadAgents.remove(AgentUnreadKey(deviceID: old.deviceID, paneID: old.paneID))
            }
        }
    }
    /// Finished agents the user has not opened since they flipped to `done`.
    @Published private(set) var unreadAgents: Set<AgentUnreadKey> = []

    @Published var showAddDevice = false
    /// Request to activate the toolbar search bar (⌘K); DetailView focuses the
    /// field and resets this back to false.
    @Published var showSearch = false
    @Published var deviceToEdit: Device?
    @Published var sshAuthenticationRequest: SSHAuthenticationRequest?
    @Published var spaceToRename: SpaceEntry?
    @Published var agentToRename: AgentEntry?
    @Published var terminalToRename: TerminalEntry?
    /// Transient action failures: shown as an alert, never by tearing down sessions.
    @Published var actionError: String?

    /// A pending destructive close, confirmed via alert before running.
    struct CloseRequest {
        let title: String
        let message: String
        let perform: () -> Void
    }
    @Published var closeRequest: CloseRequest?

    private let store = DeviceStore()
    private var services: [UUID: HerdrService] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var cwdPollTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]

    init() {
        let loaded = store.load()
        devices = loaded
        // Clear any legacy persisted device filter so the app is always in All Devices mode.
        UserDefaults.standard.removeObject(forKey: "device.filter")

        store.startMonitoring { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconcileDevicesFromStore()
            }
        }
    }

    // MARK: - Derived state

    func device(_ id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    func session(_ id: UUID) -> DeviceSessionState {
        sessions[id] ?? DeviceSessionState()
    }

    /// The herdr version the device's server reported on its last successful
    /// ping; the terminal attach uses it to pick a protocol-matching CLI binary.
    func serverVersion(deviceID: UUID) -> String? {
        if case .connected(let version) = session(deviceID).connection { return version }
        return nil
    }

    func attachmentCapabilities(
        deviceID: UUID,
        agentKind: String?
    ) -> AgentAttachmentCapabilities? {
        session(deviceID).attachmentCapabilities.capabilities(for: agentKind)
    }

    private var devicesInScope: [Device] {
        devices
    }

    /// Aggregate connection state for the current scope (footer dot, hints).
    /// Counts every device except those disabled in Settings — a disabled device's
    /// session stays `.idle` and must not make the indicator look disconnected.
    var connection: ConnectionState {
        let states = devicesInScope.filter(\.isEnabled).map { session($0.id).connection }
        if let failed = states.first(where: { if case .failed = $0 { return true }; return false }) {
            return failed
        }
        if states.contains(.connecting) { return .connecting }
        if !states.isEmpty, states.allSatisfy({ if case .connected = $0 { return true }; return false }) {
            return .connected(version: "")
        }
        return states.isEmpty ? .idle : .connecting
    }

    struct AgentEntry: Identifiable {
        let device: Device
        let agent: AgentInfo
        let tabLabel: String?
        /// The tab's stored backend name — the string `tab.rename` owns. Nil
        /// while herdr only composes a display label ("2 · pi › …").
        let tabName: String?

        var id: String { "\(device.id.uuidString)-\(agent.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: agent.paneID) }
        var title: String { agent.title(tabLabel: tabLabel) }
    }

    func agentEntry(device: Device, agent: AgentInfo) -> AgentEntry {
        let tab = session(device.id).tabs.first { $0.tabID == agent.tabID }
        return AgentEntry(
            device: device,
            agent: agent,
            tabLabel: tab?.customLabel,
            tabName: tab?.renameSeed(agentKind: agent.agentKindRaw)
        )
    }

    struct TerminalEntry: Identifiable {
        let device: Device
        let pane: PaneInfo
        let tab: TabInfo?
        let terminalID: String

        var id: String { "\(device.id.uuidString)-\(pane.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: pane.paneID) }

        var title: String {
            // The backend-stored tab label (herdr composes one, or someone
            // renamed it) wins over the pane's OSC title so a rename is always
            // visible; then the OSC title; then the directory.
            if let label = tab?.customLabel, !label.isEmpty {
                return label
            }
            if let terminalTitle = pane.terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !terminalTitle.isEmpty {
                return terminalTitle
            }
            if let cwd = pane.cwd, !cwd.isEmpty {
                let basename = URL(fileURLWithPath: cwd).lastPathComponent
                if !basename.isEmpty { return basename }
            }
            return String(localized: "Terminal")
        }
    }

    enum AttachedEntry: Identifiable {
        case agent(AgentEntry)
        case terminal(TerminalEntry)

        var id: String {
            switch self {
            case .agent(let entry): return "agent-\(entry.id)"
            case .terminal(let entry): return "terminal-\(entry.id)"
            }
        }

        var device: Device {
            switch self {
            case .agent(let entry): return entry.device
            case .terminal(let entry): return entry.device
            }
        }

        var ref: PaneRef {
            switch self {
            case .agent(let entry): return entry.ref
            case .terminal(let entry): return entry.ref
            }
        }

        var workspaceID: String {
            switch self {
            case .agent(let entry): return entry.agent.workspaceID
            case .terminal(let entry): return entry.pane.workspaceID
            }
        }

        var attachTarget: TerminalAttachTarget {
            switch self {
            case .agent(let entry): return .agent(paneID: entry.agent.paneID)
            case .terminal(let entry): return .terminal(terminalID: entry.terminalID)
            }
        }
    }

    struct SpaceEntry: Identifiable {
        let device: Device
        let workspace: WorkspaceInfo

        var id: String { "\(device.id.uuidString)-\(workspace.workspaceID)" }
        var ref: SpaceRef { SpaceRef(deviceID: device.id, workspaceID: workspace.workspaceID) }
    }

    var visibleSpaces: [SpaceEntry] {
        devicesInScope.flatMap { device in
            session(device.id).workspaces.map { SpaceEntry(device: device, workspace: $0) }
        }
    }

    /// The currently active space, determined from `selectedSpace`, the attached pane,
    /// or the first visible space in scope.
    var currentSpace: SpaceRef? {
        if let space = selectedSpace,
           devicesInScope.contains(where: { $0.id == space.deviceID }),
           session(space.deviceID).workspaces.contains(where: { $0.workspaceID == space.workspaceID }) {
            return space
        }
        if let entry = selectedAttachedEntry,
           devicesInScope.contains(where: { $0.id == entry.device.id }),
           session(entry.device.id).workspaces.contains(where: { $0.workspaceID == entry.workspaceID }) {
            return SpaceRef(deviceID: entry.device.id, workspaceID: entry.workspaceID)
        }
        if let space = visibleSpaces.first {
            return space.ref
        }
        for device in devicesInScope {
            if let workspace = session(device.id).workspaces.first {
                return SpaceRef(deviceID: device.id, workspaceID: workspace.workspaceID)
            }
        }
        return nil
    }

    /// Agents in the selected space, in herdr tab order so sidebar drag matches the TUI.
    var visibleAgents: [AgentEntry] {
        guard let space = selectedSpace, let device = device(space.deviceID) else { return [] }
        return session(space.deviceID).agents
            .filter { $0.workspaceID == space.workspaceID }
            .map { agentEntry(device: device, agent: $0) }
            .sorted { tabRank(deviceID: space.deviceID, tabID: $0.agent.tabID) < tabRank(deviceID: space.deviceID, tabID: $1.agent.tabID) }
    }

    func terminalEntries(for device: Device) -> [TerminalEntry] {
        let state = session(device.id)
        let tabsByID = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.tabID, $0) })
        return state.panes.compactMap { pane in
            guard let terminalID = pane.terminalID else { return nil }
            return TerminalEntry(
                device: device,
                pane: pane,
                tab: pane.tabID.flatMap { tabsByID[$0] },
                terminalID: terminalID
            )
        }
    }

    var visibleTerminals: [TerminalEntry] {
        guard let space = selectedSpace, let device = device(space.deviceID) else { return [] }
        return terminalEntries(for: device).filter {
            $0.pane.workspaceID == space.workspaceID
        }
    }

    func isUnread(_ entry: AgentEntry) -> Bool {
        unreadAgents.contains(AgentUnreadKey(deviceID: entry.device.id, paneID: entry.agent.paneID))
    }

    func attention(in entry: SpaceEntry) -> SpaceAttention {
        let agents = session(entry.device.id).agents.filter {
            $0.workspaceID == entry.workspace.workspaceID
        }
        return SpaceAttention.rollup(agents.map {
            (
                status: $0.status,
                unreadDone: unreadAgents.contains(
                    AgentUnreadKey(deviceID: entry.device.id, paneID: $0.paneID)
                )
            )
        })
    }

    private func tabRank(deviceID: UUID, tabID: String) -> Int {
        session(deviceID).tabs.firstIndex { $0.tabID == tabID } ?? Int.max
    }

    private func orderedTabIDs(deviceID: UUID, workspaceID: String) -> [String] {
        session(deviceID).tabs
            .filter { $0.workspaceID == workspaceID }
            .map(\.tabID)
    }

    var selectedEntry: AgentEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        guard let agent = session(selected.deviceID).agents.first(where: { $0.paneID == selected.paneID })
        else { return nil }
        return agentEntry(device: device, agent: agent)
    }

    var selectedTerminalEntry: TerminalEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        return terminalEntries(for: device).first { $0.pane.paneID == selected.paneID }
    }

    var selectedAttachedEntry: AttachedEntry? {
        if let selectedEntry { return .agent(selectedEntry) }
        if let selectedTerminalEntry { return .terminal(selectedTerminalEntry) }
        return nil
    }

    private var firstVisiblePaneRef: PaneRef? {
        visibleAgents.first?.ref ?? visibleTerminals.first?.ref
    }

    func agentCount(in entry: SpaceEntry) -> Int {
        session(entry.device.id).agents.filter { $0.workspaceID == entry.workspace.workspaceID }.count
    }

    func spaceName(deviceID: UUID, workspaceID: String) -> String {
        session(deviceID).workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    /// A space follows the directory of its selected pane (or active tab), so
    /// work created after `cd` starts in that new directory too.
    private func workspaceCWD(deviceID: UUID, workspaceID: String) -> String? {
        let state = session(deviceID)
        let preferredPaneID = selectedPane?.deviceID == deviceID ? selectedPane?.paneID : nil
        return WorkspaceDirectory.currentPath(
            workspaceID: workspaceID,
            preferredPaneID: preferredPaneID,
            workspaces: state.workspaces,
            panes: state.panes,
            agents: state.agents
        )
    }

    /// Show device badges only when more than one device is configured.
    var showsDeviceBadges: Bool {
        devices.count > 1
    }

    /// Badges on sidebar/titlebar rows are scoped by the device filter: with a
    /// single device selected every row belongs to it, so the badge says
    /// nothing. ⌘K search and the New Space picker stay on `showsDeviceBadges`
    /// because search crosses all devices regardless of the filter.
    var showsRowDeviceBadges: Bool {
        devices.count > 1
    }

    // MARK: - Selection

    func selectSpace(_ ref: SpaceRef) {
        selectedSpace = ref
        if let entry = selectedAttachedEntry {
            if entry.device.id == ref.deviceID && entry.workspaceID == ref.workspaceID { return }
        }
        selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
    }

    // MARK: - Store Reconciliation

    func reconcileDevicesFromStore() {
        let loaded = store.load()
        guard loaded != devices else { return }

        let oldDevices = devices
        let oldIDs = Set(oldDevices.map(\.id))
        let newIDs = Set(loaded.map(\.id))

        // 1. Clean up removed devices
        for removedID in oldIDs.subtracting(newIDs) {
            stopSession(removedID)
            removeSSHPassword(for: removedID)
        }

        // 2. Prepare reconciled devices preserving cached osID
        var reconciled: [Device] = []
        for var newDevice in loaded {
            if let oldDevice = oldDevices.first(where: { $0.id == newDevice.id }),
               oldDevice.sshTarget == newDevice.sshTarget {
                newDevice.osID = oldDevice.osID
            }
            reconciled.append(newDevice)
        }

        // 3. Connect, reconnect, or disconnect modified/added devices
        for newDevice in reconciled {
            if let oldDevice = oldDevices.first(where: { $0.id == newDevice.id }) {
                let targetChanged = oldDevice.sshTarget != newDevice.sshTarget
                let sessionChanged = oldDevice.session != newDevice.session
                let enabledChanged = oldDevice.isEnabled != newDevice.isEnabled

                if targetChanged || sessionChanged {
                    if targetChanged { removeSSHPassword(for: newDevice.id) }
                    stopSession(newDevice.id)
                    if newDevice.isEnabled {
                        startSession(newDevice)
                        probeOSIfNeeded(newDevice)
                    } else {
                        sessions[newDevice.id] = DeviceSessionState(connection: .idle)
                    }
                } else if enabledChanged {
                    if newDevice.isEnabled {
                        startSession(newDevice)
                        probeOSIfNeeded(newDevice)
                    } else {
                        stopSession(newDevice.id)
                        sessions[newDevice.id] = DeviceSessionState(connection: .idle)
                    }
                }
            } else {
                // Brand new device
                if newDevice.isEnabled {
                    startSession(newDevice)
                    probeOSIfNeeded(newDevice)
                } else {
                    sessions[newDevice.id] = DeviceSessionState(connection: .idle)
                }
            }
        }

        devices = reconciled
    }

    /// When jumping into a space, land on whoever still needs a look — not
    /// merely the first tab.
    private func preferredVisibleAgent() -> AgentEntry? {
        let agents = visibleAgents
        if let blocked = agents.first(where: { $0.agent.status == .blocked }) { return blocked }
        if let unread = agents.first(where: { $0.agent.status == .done && isUnread($0) }) {
            return unread
        }
        if let working = agents.first(where: { $0.agent.status == .working }) { return working }
        return agents.first
    }

    /// Jump target used by the toolbar search dropdown and by notification clicks.
    func reveal(_ ref: PaneRef) {
        let state = session(ref.deviceID)
        if let workspaceID = state.agents.first(where: { $0.paneID == ref.paneID })?.workspaceID
            ?? state.panes.first(where: { $0.paneID == ref.paneID })?.workspaceID {
            selectedSpace = SpaceRef(deviceID: ref.deviceID, workspaceID: workspaceID)
        }
        selectedPane = ref
    }

    func selectAgent(_ ref: PaneRef) {
        selectedPane = ref
    }

    // MARK: - Lifecycle

    func start() {
        NotificationManager.shared.setup(model: self)
        // Finder-launched apps have launchd's PATH. Capture the login +
        // interactive shell environment on a background thread once; terminal
        // attach reads the same snapshot.
        Task.detached(priority: .utility) {
            _ = await ShellEnvironment.ensure()
        }
        for device in devices {
            if device.isLocal || device.isEnabled {
                startSession(device)
                probeOSIfNeeded(device)
            } else {
                sessions[device.id] = DeviceSessionState(connection: .idle)
            }
        }
    }

    func service(for device: Device) -> HerdrService {
        if let service = services[device.id] { return service }
        let service = HerdrService(device: device)
        services[device.id] = service
        return service
    }

    /// Runs one device's session: connect, snapshot, event stream, and reconnect
    /// with exponential backoff (1s → 30s) whenever the connection drops.
    private func startSession(_ device: Device) {
        sessionTasks[device.id]?.cancel()
        if sessions[device.id] == nil { sessions[device.id] = DeviceSessionState() }
        let service = service(for: device)
        sessionTasks[device.id] = Task { [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                self.sessions[device.id]?.connection = .connecting
                do {
                    let pong = try await service.connect()
                    self.sessions[device.id]?.connection = .connected(version: pong.version)
                    backoff = 1
                    // retried on every successful connect until it sticks (a fresh
                    // device's first probes can fail before its host key is known)
                    if let current = self.device(device.id) {
                        self.probeOSIfNeeded(current)
                    }
                    await self.refresh(device.id)
                    await self.loadAttachmentCapabilities(deviceID: device.id, using: service)
                    self.cwdPollTasks[device.id]?.cancel()
                    self.cwdPollTasks[device.id] = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard !Task.isCancelled else { return }
                            await self?.refresh(device.id)
                        }
                    }
                    let stream = try await service.events()
                    for try await _ in stream {
                        self.scheduleRefresh(device.id)
                    }
                    self.cwdPollTasks[device.id]?.cancel()
                    self.cwdPollTasks[device.id] = nil
                } catch {
                    self.cwdPollTasks[device.id]?.cancel()
                    self.cwdPollTasks[device.id] = nil
                    self.sessions[device.id]?.connection = .failed(error.localizedDescription)
                    if let target = device.sshTarget, Self.isSSHAuthenticationFailure(error) {
                        self.sshAuthenticationRequest = SSHAuthenticationRequest(
                            deviceID: device.id,
                            target: target
                        )
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// Manifests feed the attachment-capability registry (paste path vs upload).
    private func loadAttachmentCapabilities(deviceID: UUID, using service: HerdrService) async {
        do {
            let manifests = try await service.agentManifests()
            sessions[deviceID]?.attachmentCapabilities =
                AgentAttachmentCapabilityRegistry(manifests: manifests)
        } catch {
            sessions[deviceID]?.attachmentCapabilities = AgentAttachmentCapabilityRegistry()
        }
    }

    /// Tears down every live tunnel. Awaited from the app's terminate hook — `stopSession`
    /// fires its disconnect in a detached `Task`, which never runs when the process is exiting.
    func shutdownAllSessions() async {
        store.stopMonitoring()
        let live = services
        services.removeAll()
        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        cwdPollTasks.values.forEach { $0.cancel() }
        cwdPollTasks.removeAll()
        for service in live.values {
            await service.disconnect()
        }
    }

    private func stopSession(_ id: UUID) {
        sessionTasks[id]?.cancel()
        sessionTasks[id] = nil
        cwdPollTasks[id]?.cancel()
        cwdPollTasks[id] = nil
        refreshDebounces[id]?.cancel()
        refreshDebounces[id] = nil
        previousStatuses[id] = nil
        let service = services[id]
        services[id] = nil
        sessions[id] = nil
        Task { await service?.disconnect() }
    }

    func addDevice(name: String, sshTarget: String, session: String = "default") async throws {
        let trimmedSession = session.trimmingCharacters(in: .whitespaces)
        let resolvedSession = trimmedSession.isEmpty ? "default" : trimmedSession
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTarget = sshTarget.trimmingCharacters(in: .whitespaces)
        let resolvedName = trimmedName.isEmpty ? trimmedTarget : trimmedName

        try await HerdrMachineCLI.add(
            target: trimmedTarget,
            label: resolvedName,
            session: resolvedSession
        )

        reconcileDevicesFromStore()
    }

    func saveSSHPassword(_ password: String, for request: SSHAuthenticationRequest) {
        guard !password.isEmpty,
              let device = device(request.deviceID),
              device.sshTarget == request.target
        else { return }
        do {
            try SSHCredentialStore.setPassword(password, for: device.id)
            sshAuthenticationRequest = nil
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Leaves the device disconnected but recoverable; the reconnect loop stopped at the prompt.
    func cancelSSHAuthentication(for request: SSHAuthenticationRequest) {
        sshAuthenticationRequest = nil
        sessions[request.deviceID]?.connection =
            .failed(String(localized: "Authentication cancelled — choose Reconnect to try again"))
    }

    var hasReconnectableDevice: Bool {
        devicesInScope.contains { $0.isEnabled && isFailed($0.id) }
    }

    func reconnectFailedDevices() {
        for device in devicesInScope where device.isEnabled && isFailed(device.id) {
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        }
    }

    private func isFailed(_ deviceID: UUID) -> Bool {
        if case .failed = session(deviceID).connection { return true }
        return false
    }

    /// Renames a device and/or updates its SSH target, session, or enabled state via official herdr CLI.
    func updateDevice(
        _ id: UUID,
        name: String,
        sshTarget: String,
        session: String = "default",
        isEnabled: Bool = true
    ) async throws {
        guard let current = device(id), !current.isLocal else { return }
        let targetChanged = current.sshTarget != sshTarget
        let sessionChanged = current.session != session
        let nameChanged = current.name != name
        let enabledChanged = current.isEnabled != isEnabled

        let profileID = id.profileIDString

        if targetChanged || sessionChanged {
            try await HerdrMachineCLI.remove(profileID: profileID)
            try await HerdrMachineCLI.add(
                target: sshTarget,
                label: name,
                session: session.isEmpty ? "default" : session
            )
            if !isEnabled {
                if let updated = store.load().first(where: { $0.sshTarget == sshTarget }) {
                    try? await HerdrMachineCLI.disable(profileID: updated.id.profileIDString)
                }
            }
        } else {
            if nameChanged {
                try await HerdrMachineCLI.rename(profileID: profileID, label: name)
            }
            if enabledChanged {
                if isEnabled {
                    try await HerdrMachineCLI.enable(profileID: profileID)
                } else {
                    try await HerdrMachineCLI.disable(profileID: profileID)
                }
            }
        }

        reconcileDevicesFromStore()
    }

    func setDeviceEnabled(_ device: Device, enabled: Bool) {
        guard !device.isLocal else { return }
        Task {
            if enabled {
                try? await HerdrMachineCLI.enable(profileID: device.id.profileIDString)
            } else {
                try? await HerdrMachineCLI.disable(profileID: device.id.profileIDString)
            }
            await MainActor.run {
                self.reconcileDevicesFromStore()
            }
        }
    }

    func toggleDeviceEnabled(_ device: Device) {
        setDeviceEnabled(device, enabled: !device.isEnabled)
    }

    func removeDevice(_ device: Device) {
        guard !device.isLocal else { return }
        removeSSHPassword(for: device.id)
        if sshAuthenticationRequest?.deviceID == device.id { sshAuthenticationRequest = nil }
        stopSession(device.id)
        devices.removeAll { $0.id == device.id }
        if selectedSpace?.deviceID == device.id {
            selectedSpace = visibleSpaces.first(where: { $0.device.id != device.id })?.ref
        }
        if selectedPane?.deviceID == device.id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
        Task {
            try? await HerdrMachineCLI.remove(profileID: device.id.profileIDString)
            await MainActor.run {
                self.reconcileDevicesFromStore()
            }
        }
    }

    // MARK: - Refresh

    func refresh(_ deviceID: UUID) async {
        guard let device = device(deviceID), let service = services[deviceID] else { return }
        do {
            let snapshot = try await service.snapshot()
            let workspaceCWDs: [String: String] = Dictionary(uniqueKeysWithValues: snapshot.workspaces.compactMap { workspace in
                guard let cwd = snapshot.workspaceCWD(workspaceID: workspace.workspaceID) else { return nil }
                return (workspace.workspaceID, cwd)
            })
            unreadAgents = AgentUnread.applying(
                previous: previousStatuses[deviceID] ?? [:],
                agents: snapshot.agents,
                unread: unreadAgents,
                deviceID: device.id
            )
            notifyTransitions(
                device: device,
                from: previousStatuses[deviceID] ?? [:],
                to: snapshot.agents,
                workspaces: snapshot.workspaces,
                tabs: snapshot.tabs ?? []
            )
            previousStatuses[deviceID] = Dictionary(
                uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.status) }
            )
            sessions[deviceID]?.agents = snapshot.agents
            sessions[deviceID]?.workspaces = snapshot.workspaces
            sessions[deviceID]?.tabs = Self.orderedTabs(
                snapshot.tabs ?? [],
                workspaces: snapshot.workspaces
            )
            sessions[deviceID]?.panes = snapshot.ordinaryTerminalPanes
            sessions[deviceID]?.workspaceCWDs = workspaceCWDs
            let paneIDs = Set((snapshot.panes ?? []).map(\.paneID))
                .union(snapshot.agents.map(\.paneID))
            if let selected = selectedPane, selected.deviceID == deviceID,
               !paneIDs.contains(selected.paneID) {
                selectedPane = nil
            }
            if let space = selectedSpace, space.deviceID == deviceID,
               !snapshot.workspaces.contains(where: { $0.workspaceID == space.workspaceID }) {
                selectedSpace = nil
            }
            if selectedSpace == nil {
                if let focusedWorkspaceID = snapshot.focusedWorkspaceID,
                   snapshot.workspaces.contains(where: { $0.workspaceID == focusedWorkspaceID }) {
                    selectedSpace = SpaceRef(deviceID: deviceID, workspaceID: focusedWorkspaceID)
                } else {
                    selectedSpace = visibleSpaces.first?.ref
                }
            }
            // Selection is manual only: a periodic refresh must never pick or
            // jump a pane for the user. The pane they clicked stays selected;
            // if they have nothing selected it stays unselected until they click.
        } catch {
            sessions[deviceID]?.connection = .failed(error.localizedDescription)
        }
    }

    private func scheduleRefresh(_ deviceID: UUID) {
        refreshDebounces[deviceID]?.cancel()
        refreshDebounces[deviceID] = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self.refresh(deviceID)
        }
    }

    /// Notifies when an agent newly becomes blocked (needs input) or done (finished
    /// while unwatched). Initial snapshots don't notify — only real transitions do.
    private func notifyTransitions(
        device: Device,
        from previous: [String: AgentStatus],
        to agents: [AgentInfo],
        workspaces: [WorkspaceInfo],
        tabs: [TabInfo]
    ) {
        guard !previous.isEmpty else { return }
        for agent in agents {
            guard let old = previous[agent.paneID], old != agent.status else { continue }
            guard agent.status == .blocked || agent.status == .done else { continue }
            let tabLabel = tabs.first { $0.tabID == agent.tabID }?.customLabel
            NotificationManager.shared.post(
                agent: agent,
                title: agent.title(tabLabel: tabLabel),
                status: agent.status,
                deviceID: device.id,
                deviceName: device.name,
                spaceName: workspaces.first { $0.workspaceID == agent.workspaceID }?.label ?? agent.workspaceID
            )
        }
    }

    /// Sniffs the device OS once (for the OS brand icon) and caches it in memory.
    private func probeOSIfNeeded(_ device: Device) {
        guard device.osID == nil, let target = device.sshTarget else { return }
        Task {
            guard let os = try? await SSHTunnel.probeOS(
                target: target,
                credentialID: device.id
            ) else { return }
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.devices[index].osID = os
            }
        }
    }

    private static func isSSHAuthenticationFailure(_ error: Error) -> Bool {
        guard let herdrError = error as? HerdrError,
              case .tunnelFailed(let reason) = herdrError
        else { return false }
        return [
            "permission denied",
            "authentication failed",
            "too many authentication failures",
            "no supported authentication methods",
        ].contains { reason.localizedCaseInsensitiveContains($0) }
    }

    private func removeSSHPassword(for deviceID: UUID) {
        do {
            try SSHCredentialStore.removePassword(for: deviceID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// An action fired while the device session is down surfaces the bare
    /// "connection failed: not connected", which points at nothing. The
    /// reconnect loop already knows why the device is unreachable — say that
    /// instead. (#21)
    func actionErrorMessage(_ error: Error, device: Device) -> String {
        guard let herdrError = error as? HerdrError,
              case .connectionFailed(let reason) = herdrError,
              reason == "not connected"
        else { return error.localizedDescription }
        switch session(device.id).connection {
        case .connecting:
            return String(localized: "Still connecting to \(device.name) — try again in a moment.")
        case .failed(let reason):
            return String(localized: "\(device.name) is unreachable: \(reason)")
        case .idle:
            return String(localized: "\(device.name) isn't connected.")
        case .connected:
            return String(localized: "\(device.name) just reconnected — try again.")
        }
    }

    // MARK: - Closing

    func requestCloseSpace(_ entry: SpaceEntry) {
        closeRequest = CloseRequest(
            title: String(localized: "Close space \"\(entry.workspace.label)\" on \(entry.device.name)?"),
            message: String(localized: "All terminals and agents in this space will be closed.")
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.service(for: entry.device)
                        .closeWorkspace(workspaceID: entry.workspace.workspaceID)
                    if self.selectedSpace == entry.ref { self.selectedSpace = nil }
                    await self.refresh(entry.device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: entry.device)
                }
            }
        }
    }

    func requestClosePane(_ ref: PaneRef, name: String) {
        guard let device = device(ref.deviceID) else { return }
        closeRequest = CloseRequest(
            title: String(localized: "Close \"\(name)\"?"),
            message: String(localized: "The pane and whatever is running inside it will be terminated.")
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.service(for: device).closePane(paneID: ref.paneID)
                    if self.selectedPane == ref { self.selectedPane = nil }
                    await self.refresh(device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: device)
                }
            }
        }
    }

    // MARK: - Actions

    /// Closes the currently selected agent or terminal pane (⌘W), asking for
    /// confirmation before terminating whatever is running inside it.
    func closeCurrentPane() {
        if let entry = selectedEntry {
            requestClosePane(entry.ref, name: entry.title)
        } else if let entry = selectedTerminalEntry {
            requestClosePane(entry.ref, name: entry.title)
        }
    }

    /// Renames a space in the backend (`workspace.rename`); herdr is the sole
    /// owner of space names, so herdrm never writes one on its own.
    func renameSpace(_ entry: SpaceEntry, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != entry.workspace.label else { return }
        Task {
            do {
                try await service(for: entry.device).renameWorkspace(
                    workspaceID: entry.workspace.workspaceID,
                    label: label
                )
                await refresh(entry.device.id)
            } catch {
                actionError = actionErrorMessage(error, device: entry.device)
            }
        }
    }

    /// Renames an agent's tab in the backend (`tab.rename`) — the same RPC the
    /// herdr TUI's rename uses, so both UIs show the same name afterwards.
    func renameAgent(_ entry: AgentEntry, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.tabName else { return }
        Task {
            do {
                try await service(for: entry.device).renameTab(
                    tabID: entry.agent.tabID,
                    label: name
                )
                await refresh(entry.device.id)
            } catch {
                actionError = actionErrorMessage(error, device: entry.device)
            }
        }
    }

    /// Renames a terminal tab in the backend (`tab.rename`), matching the
    /// herdr TUI's tab rename.
    func renameTerminal(_ entry: TerminalEntry, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tabID = entry.pane.tabID,
              !name.isEmpty,
              name != entry.tab?.renameSeed(agentKind: nil)
        else { return }
        Task {
            do {
                try await service(for: entry.device).renameTab(
                    tabID: tabID,
                    label: name
                )
                await refresh(entry.device.id)
            } catch {
                actionError = actionErrorMessage(error, device: entry.device)
            }
        }
    }

    /// Reorders a Space by dropping it on another Space of the same device.
    /// Cross-device drops are ignored; herdr remains the source of truth after refresh.
    func moveSpace(_ source: SpaceEntry, onto target: SpaceEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id else { return }
        let orderedIDs = session(source.device.id).workspaces.map(\.workspaceID)
        guard let plan = WorkspaceReorder.plan(
            moving: source.workspace.workspaceID,
            onto: target.workspace.workspaceID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[source.device.id]?.workspaces {
            sessions[source.device.id]?.workspaces = WorkspaceReorder.applying(
                current,
                id: \.workspaceID,
                plan: plan
            )
        }

        Task {
            do {
                try await service(for: source.device).moveWorkspaceBlock(
                    workspaceIDs: plan.workspaceIDs,
                    beforeWorkspaceID: plan.beforeWorkspaceID
                )
                await refresh(source.device.id)
            } catch {
                await refresh(source.device.id)
                actionError = actionErrorMessage(error, device: source.device)
            }
        }
    }

    /// Reorders an agent tab by dropping it on another agent in the same space.
    /// Cross-space and cross-device drops are ignored (`tab.move` is in-workspace).
    func moveAgent(_ source: AgentEntry, onto target: AgentEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id,
              source.agent.workspaceID == target.agent.workspaceID
        else { return }
        let orderedIDs = orderedTabIDs(
            deviceID: source.device.id,
            workspaceID: source.agent.workspaceID
        )
        guard let insertIndex = TabReorder.insertIndex(
            moving: source.agent.tabID,
            onto: target.agent.tabID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }
        guard let plan = WorkspaceReorder.plan(
            moving: source.agent.tabID,
            onto: target.agent.tabID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[source.device.id]?.tabs {
            let scoped = current.filter { $0.workspaceID == source.agent.workspaceID }
            let reordered = WorkspaceReorder.applying(scoped, id: \.tabID, plan: plan)
            sessions[source.device.id]?.tabs = Self.replacingTabs(
                current,
                workspaceID: source.agent.workspaceID,
                with: reordered
            )
        }

        Task {
            do {
                try await service(for: source.device).moveTab(
                    tabID: source.agent.tabID,
                    insertIndex: insertIndex
                )
                await refresh(source.device.id)
            } catch {
                await refresh(source.device.id)
                actionError = actionErrorMessage(error, device: source.device)
            }
        }
    }

    private static func orderedTabs(_ tabs: [TabInfo], workspaces: [WorkspaceInfo]) -> [TabInfo] {
        let wsIndex = Dictionary(uniqueKeysWithValues: workspaces.enumerated().map {
            ($1.workspaceID, $0)
        })
        return tabs.sorted {
            let w0 = wsIndex[$0.workspaceID] ?? Int.max
            let w1 = wsIndex[$1.workspaceID] ?? Int.max
            if w0 != w1 { return w0 < w1 }
            return ($0.number ?? Int.max) < ($1.number ?? Int.max)
        }
    }

    private static func replacingTabs(
        _ tabs: [TabInfo],
        workspaceID: String,
        with reordered: [TabInfo]
    ) -> [TabInfo] {
        var result: [TabInfo] = []
        var inserted = false
        for tab in tabs {
            if tab.workspaceID == workspaceID {
                if !inserted {
                    result.append(contentsOf: reordered)
                    inserted = true
                }
            } else {
                result.append(tab)
            }
        }
        if !inserted { result.append(contentsOf: reordered) }
        return result
    }

    /// Creates a default Herdr space, whose root pane is its initial terminal.
    /// herdr itself names the space from its directory; renaming is the only
    /// way the label changes.
    func createNewSpace(on device: Device) {
        Task {
            do {
                let service = service(for: device)
                let created = try await service.createWorkspace(label: nil, cwd: nil)
                let paneID: String
                if let rootPaneID = created.rootPaneID {
                    paneID = rootPaneID
                } else {
                    paneID = try await service.createTab(
                        workspaceID: created.workspaceID,
                        cwd: nil,
                        label: nil
                    )
                }
                await refresh(device.id)
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: created.workspaceID)
                selectedPane = PaneRef(deviceID: device.id, paneID: paneID)
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// Creates a persistent shell tab in the current space, or in the default space of the active device.
    func startNewTerminal() {
        if let space = currentSpace, let device = device(space.deviceID) {
            startNewTerminal(device: device, workspaceID: space.workspaceID)
            return
        }
        guard let device = devices.first(where: { $0.isEnabled && $0.isLocal })
            ?? devices.first(where: { $0.isEnabled })
            ?? devices.first else {
            actionError = String(localized: "No device available to open a terminal.")
            return
        }
        if let firstWorkspace = session(device.id).workspaces.first {
            startNewTerminal(device: device, workspaceID: firstWorkspace.workspaceID)
        } else {
            startNewTerminal(device: device, workspaceID: nil)
        }
    }

    /// Creates a persistent shell tab on the selected Herdr device. Local and
    /// remote terminals use the same server-owned lifecycle and can be detached
    /// and reattached without killing the shell process.
    func startNewTerminal(device: Device, workspaceID: String?) {
        Task {
            do {
                let service = service(for: device)
                let targetCWD = workspaceID.flatMap { workspaceCWD(deviceID: device.id, workspaceID: $0) }
                let paneID = try await service.createTab(
                    workspaceID: workspaceID,
                    cwd: targetCWD,
                    label: nil
                )
                await refresh(device.id)
                let resolvedWorkspaceID = workspaceID
                    ?? session(device.id).panes.first(where: { $0.paneID == paneID })?.workspaceID
                    ?? session(device.id).workspaces.first?.workspaceID
                if let resolvedWorkspaceID {
                    selectedSpace = SpaceRef(deviceID: device.id, workspaceID: resolvedWorkspaceID)
                }
                selectedPane = PaneRef(deviceID: device.id, paneID: paneID)
                if session(device.id).panes.first(where: { $0.paneID == paneID }) == nil {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await refresh(device.id)
                }
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// Creates a new space on the default device.
    func createNewSpace() {
        if let device = devices.first(where: { $0.isEnabled && $0.isLocal }) ?? devices.first(where: { $0.isEnabled }) ?? devices.first {
            createNewSpace(on: device)
        }
    }

}

