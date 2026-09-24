import Foundation
import HerdrKit
import SwiftUI

extension AppModel {
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
    func startSession(_ device: Device) {
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
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
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
    func loadAttachmentCapabilities(deviceID: UUID, using service: HerdrService) async {
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

    func stopSession(_ id: UUID) {
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

    // MARK: - Refresh

    func refresh(_ deviceID: UUID) async {
        guard let device = device(deviceID), let service = services[deviceID] else { return }
        do {
            let snapshot = try await service.snapshot()
            let workspaceCWDs: [String: String] = Dictionary(uniqueKeysWithValues: snapshot.workspaces.compactMap { workspace in
                guard let cwd = snapshot.workspaceCWD(workspaceID: workspace.workspaceID) else { return nil }
                return (workspace.workspaceID, cwd)
            })
            let nextUnread = AgentUnread.applying(
                previous: previousStatuses[deviceID] ?? [:],
                agents: snapshot.agents,
                unread: unreadAgents,
                deviceID: device.id
            )
            if unreadAgents != nextUnread {
                replaceUnreadAgents(with: nextUnread)
            }
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
            let nextTabs = Self.orderedTabs(
                snapshot.tabs ?? [],
                workspaces: snapshot.workspaces
            )
            var current = sessions[deviceID] ?? DeviceSessionState()
            if current.agents != snapshot.agents ||
               current.workspaces != snapshot.workspaces ||
               current.tabs != nextTabs ||
               current.panes != snapshot.ordinaryTerminalPanes ||
               current.workspaceCWDs != workspaceCWDs {
                current.agents = snapshot.agents
                current.workspaces = snapshot.workspaces
                current.tabs = nextTabs
                current.panes = snapshot.ordinaryTerminalPanes
                current.workspaceCWDs = workspaceCWDs
                sessions[deviceID] = current
            }
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
            // Selection is manual only: a periodic refresh must never pick or
            // jump a space or pane for the user. What they clicked stays selected;
            // if they have nothing selected it stays unselected until they click.
        } catch {
            sessions[deviceID]?.connection = .failed(error.localizedDescription)
        }
    }

    func scheduleRefresh(_ deviceID: UUID) {
        refreshDebounces[deviceID]?.cancel()
        refreshDebounces[deviceID] = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self.refresh(deviceID)
        }
    }

    /// Notifies when an agent newly becomes blocked (needs input) or done (finished
    /// while unwatched). Initial snapshots don't notify — only real transitions do.
    func notifyTransitions(
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
    func probeOSIfNeeded(_ device: Device) {
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

    func removeSSHPassword(for deviceID: UUID) {
        do {
            try SSHCredentialStore.removePassword(for: deviceID)
        } catch {
            actionError = error.localizedDescription
        }
    }

}
