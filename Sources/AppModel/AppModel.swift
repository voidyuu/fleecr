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
struct DeviceSessionState: Equatable {
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

    let store = DeviceStore()
    var services: [UUID: HerdrService] = [:]
    var sessionTasks: [UUID: Task<Void, Never>] = [:]
    var cwdPollTasks: [UUID: Task<Void, Never>] = [:]
    var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    var previousStatuses: [UUID: [String: AgentStatus]] = [:]

    func replaceUnreadAgents(with agents: Set<AgentUnreadKey>) {
        unreadAgents = agents
    }

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

}
