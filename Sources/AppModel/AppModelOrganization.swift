import Foundation
import HerdrKit
import SwiftUI

extension AppModel {
    /// Renames a space in the backend (`workspace.rename`); herdr is the sole
    /// owner of space names, so fleecr never writes one on its own.
    func renameSpace(_ entry: SpaceEntry, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != entry.workspace.label else { return }
        performAction(on: entry.device) {
            try await self.service(for: entry.device).renameWorkspace(
                workspaceID: entry.workspace.workspaceID,
                label: label
            )
        }
    }

    /// Renames an agent's tab in the backend (`tab.rename`) — the same RPC the
    /// herdr TUI's rename uses, so both UIs show the same name afterwards.
    func renameAgent(_ entry: AgentEntry, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.tabName else { return }
        performAction(on: entry.device) {
            try await self.service(for: entry.device).renameTab(
                tabID: entry.agent.tabID,
                label: name
            )
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
        performAction(on: entry.device) {
            try await self.service(for: entry.device).renameTab(tabID: tabID, label: name)
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

        performAction(on: source.device, refreshOnFailure: true) {
            try await self.service(for: source.device).moveWorkspaceBlock(
                workspaceIDs: plan.workspaceIDs,
                beforeWorkspaceID: plan.beforeWorkspaceID
            )
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

        performAction(on: source.device, refreshOnFailure: true) {
            try await self.service(for: source.device).moveTab(
                tabID: source.agent.tabID,
                insertIndex: insertIndex
            )
        }
    }

    private func performAction(
        on device: Device,
        refreshOnFailure: Bool = false,
        action: @escaping () async throws -> Void
    ) {
        Task {
            do {
                try await action()
                await refresh(device.id)
            } catch {
                if refreshOnFailure { await refresh(device.id) }
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    static func orderedTabs(_ tabs: [TabInfo], workspaces: [WorkspaceInfo]) -> [TabInfo] {
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
