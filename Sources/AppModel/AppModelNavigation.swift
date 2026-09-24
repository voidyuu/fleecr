import Foundation
import HerdrKit
import SwiftUI

extension AppModel {
    // MARK: - Selection

    func selectSpace(_ ref: SpaceRef) {
        selectedSpace = ref
        if let entry = selectedAttachedEntry {
            if entry.device.id == ref.deviceID && entry.workspaceID == ref.workspaceID { return }
        }
        selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
    }

    func preferredVisibleAgent() -> AgentEntry? {
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

    func requestClosePane(_ ref: PaneRef, name: String) {
        guard let device = device(ref.deviceID) else { return }
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

    // MARK: - Actions

    /// Closes the currently selected agent or terminal pane (⌘W).
    func closeCurrentPane() {
        if let entry = selectedEntry {
            requestClosePane(entry.ref, name: entry.title)
        } else if let entry = selectedTerminalEntry {
            requestClosePane(entry.ref, name: entry.title)
        }
    }

    /// All selectable tab pane references in the currently active space,
    /// combining both agent tabs and terminal tabs.
    var allVisibleTabPaneRefs: [PaneRef] {
        if selectedSpace == nil, let fallback = currentSpace {
            selectedSpace = fallback
        }
        return visibleAgents.map(\.ref) + visibleTerminals.map(\.ref)
    }

    /// Cycles to the next tab (agent or terminal) in the current space.
    func selectNextTab() {
        let tabs = allVisibleTabPaneRefs
        guard !tabs.isEmpty else { return }
        if let current = selectedPane, let currentIndex = tabs.firstIndex(of: current) {
            let nextIndex = (currentIndex + 1) % tabs.count
            selectedPane = tabs[nextIndex]
        } else {
            selectedPane = tabs.first
        }
    }

    /// Cycles to the previous tab (agent or terminal) in the current space.
    func selectPreviousTab() {
        let tabs = allVisibleTabPaneRefs
        guard !tabs.isEmpty else { return }
        if let current = selectedPane, let currentIndex = tabs.firstIndex(of: current) {
            let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
            selectedPane = tabs[prevIndex]
        } else {
            selectedPane = tabs.last
        }
    }

}
