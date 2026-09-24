import HerdrKit
import SwiftUI

/// Sidebar search (⌘K): instead of a results dropdown, the query filters the
/// left sidebar in place — same group layout, only rows matching the text stay.
/// Matching mirrors the old command palette (title, agent kind, tab label, cwd,
/// device, space), split into per-group predicates so each section filters itself.
@MainActor
enum SidebarSearch {
    /// Trimmed, lowercased query shared by all matches.
    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Empty (or fully whitespace) queries match everything — the "no filter" state.
    static func isActive(_ query: String) -> Bool {
        !normalize(query).isEmpty
    }

    static func matches(_ entry: AppModel.SpaceEntry, query: String, model: AppModel) -> Bool {
        let q = normalize(query)
        return q.isEmpty
            || entry.workspace.label.lowercased().contains(q)
            || entry.device.name.lowercased().contains(q)
            || model.spaceName(deviceID: entry.device.id, workspaceID: entry.workspace.workspaceID)
                .lowercased().contains(q)
    }

    static func matches(_ entry: AppModel.AgentEntry, query: String, model: AppModel) -> Bool {
        let q = normalize(query)
        return q.isEmpty
            || entry.title.lowercased().contains(q)
            || entry.agent.title.lowercased().contains(q)
            || entry.agent.agent.lowercased().contains(q)
            || (entry.agent.name?.lowercased().contains(q) ?? false)
            || (entry.tabLabel?.lowercased().contains(q) ?? false)
            || (entry.agent.terminalTitleStripped ?? entry.agent.terminalTitle)?
                .lowercased().contains(q) == true
            || entry.device.name.lowercased().contains(q)
            || model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID)
                .lowercased().contains(q)
    }

    static func matches(_ entry: AppModel.TerminalEntry, query: String, model: AppModel) -> Bool {
        let q = normalize(query)
        return q.isEmpty
            || entry.title.lowercased().contains(q)
            || (entry.pane.cwd?.lowercased().contains(q) ?? false)
            || (entry.tab?.label.lowercased().contains(q) ?? false)
            || entry.device.name.lowercased().contains(q)
            || model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID)
                .lowercased().contains(q)
    }

    /// Flat result list used when a search is active: `all agents` across every
    /// device and space (not just the selected one), each filtered by the query.
    /// With no active query this falls back to the sidebar's current per-space scoping.
    static func matchingAgents(model: AppModel, query: String) -> [AppModel.AgentEntry] {
        guard isActive(query) else { return model.visibleAgents }
        return model.devices.flatMap { device in
            model.session(device.id).agents.map { model.agentEntry(device: device, agent: $0) }
                .filter { matches($0, query: query, model: model) }
        }
    }

    /// Flat terminals across every device and space (not just the current one).
    static func matchingTerminals(model: AppModel, query: String) -> [AppModel.TerminalEntry] {
        guard isActive(query) else { return model.visibleTerminals }
        return model.devices.flatMap { model.terminalEntries(for: $0) }
            .filter { matches($0, query: query, model: model) }
    }
}