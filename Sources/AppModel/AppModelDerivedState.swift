import Foundation
import HerdrKit
import SwiftUI

extension AppModel {
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

    var devicesInScope: [Device] {
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
        let currentSession = session(space.deviceID)
        let tabRanks = Dictionary(uniqueKeysWithValues: currentSession.tabs.enumerated().map { ($1.tabID, $0) })
        return currentSession.agents
            .filter { $0.workspaceID == space.workspaceID }
            .map { agentEntry(device: device, agent: $0) }
            .sorted { (tabRanks[$0.agent.tabID] ?? Int.max) < (tabRanks[$1.agent.tabID] ?? Int.max) }
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
        let state = session(device.id)
        let tabsByID = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.tabID, $0) })
        let tabRanks = Dictionary(uniqueKeysWithValues: state.tabs.enumerated().map { ($1.tabID, $0) })
        return state.panes.compactMap { pane in
            guard pane.workspaceID == space.workspaceID, let terminalID = pane.terminalID else { return nil }
            return TerminalEntry(
                device: device,
                pane: pane,
                tab: pane.tabID.flatMap { tabsByID[$0] },
                terminalID: terminalID
            )
        }
        .sorted { (tabRanks[$0.pane.tabID ?? ""] ?? Int.max) < (tabRanks[$1.pane.tabID ?? ""] ?? Int.max) }
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

    func orderedTabIDs(deviceID: UUID, workspaceID: String) -> [String] {
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

    var firstVisiblePaneRef: PaneRef? {
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
    func workspaceCWD(deviceID: UUID, workspaceID: String) -> String? {
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

}
