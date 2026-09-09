import HerdrKit
import SwiftUI

/// Search index shared by the toolbar search bar (⌘K): a native-style long field in
/// the titlebar band whose results appear in a dropdown anchored below it. Ranking
/// mirrors the old command palette: needs input, unread, working, then the rest.
@MainActor
enum SearchIndex {
    enum Result: Identifiable {
        case agent(AppModel.AgentEntry)
        case terminal(AppModel.TerminalEntry)
        case space(AppModel.SpaceEntry)

        var id: String {
            switch self {
            case .agent(let entry): return "agent-\(entry.id)"
            case .terminal(let entry): return "terminal-\(entry.id)"
            case .space(let entry): return "space-\(entry.id)"
            }
        }
    }

    /// All agents, terminals, and spaces across devices, filtered by `query`
    /// (title, agent kind, tab label, cwd, device, space) and ranked by urgency.
    static func results(model: AppModel, query: String) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let agents = model.devices.flatMap { device in
            model.session(device.id).agents.map { model.agentEntry(device: device, agent: $0) }
        }.filter { entry in
            q.isEmpty
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
        let spaces = model.devices.flatMap { device in
            model.session(device.id).workspaces.map { AppModel.SpaceEntry(device: device, workspace: $0) }
        }.filter { entry in
            q.isEmpty
                || entry.workspace.label.lowercased().contains(q)
                || entry.device.name.lowercased().contains(q)
        }
        let terminals = model.devices.flatMap { model.terminalEntries(for: $0) }.filter { entry in
            q.isEmpty
                || entry.title.lowercased().contains(q)
                || (entry.pane.cwd?.lowercased().contains(q) ?? false)
                || (entry.tab?.label.lowercased().contains(q) ?? false)
                || entry.device.name.lowercased().contains(q)
                || model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID)
                    .lowercased().contains(q)
        }
        // Sidebar follows herdr tab order so drag-reorder sticks. Search still
        // ranks by urgency: needs input, unread, working, then the rest.
        let ranked = agents.sorted {
            let r0 = rank($0, model: model)
            let r1 = rank($1, model: model)
            if r0 != r1 { return r0 < r1 }
            return ($0.agent.revision ?? 0) > ($1.agent.revision ?? 0)
        }
        return ranked.map(Result.agent) + terminals.map(Result.terminal) + spaces.map(Result.space)
    }

    private static func rank(_ entry: AppModel.AgentEntry, model: AppModel) -> Int {
        switch entry.agent.status {
        case .blocked: return 0
        case .done where model.isUnread(entry): return 1
        case .working: return 2
        case .done: return 3
        case .idle: return 4
        case .unknown: return 5
        }
    }
}

/// Results shown in a dropdown that hangs below the toolbar search bar. Frosted
/// material, hairline border, and a soft shadow so it reads as a floating menu
/// over the terminal instead of pushing content around.
struct SearchResultsDropdown: View {
    @ObservedObject var model: AppModel
    @Binding var highlighted: Int
    let results: [SearchIndex.Result]
    var onChoose: (SearchIndex.Result) -> Void

    /// Matches the toolbar search bar's fixed width so the dropdown reads as
    /// part of the field.
    static let width: CGFloat = 440

    /// Rows are 36pt with 1pt spacing and 6pt list padding; the dropdown hugs its
    /// content and only scrolls past this cap.
    private var listHeight: CGFloat {
        min(CGFloat(results.count) * 36 + CGFloat(max(results.count - 1, 0)) + 12, 320)
    }

    var body: some View {
        Group {
            if results.isEmpty {
                Text("No matches")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                SearchResultRow(model: model, result: result, isHighlighted: index == highlighted)
                                    .onTapGesture { onChoose(result) }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: listHeight)
                    // anchor: nil moves the minimum to reveal the row — a no-op when it
                    // is already visible, so hovering never yanks the scroll position.
                    .onChange(of: highlighted) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id, anchor: nil)
                    }
                    .onAppear {
                        if let first = results.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
        }
        .frame(width: max(Self.width, 240))
        // Clip the scrolling rows to the rounded container so content never
        // bleeds past the top/bottom corners while the list slides.
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }
}

/// One result row: agent / terminal / space icon, title, status glyph, and the
/// trailing "kind · space · device" context, same content as the sidebar rows.
struct SearchResultRow: View {
    @ObservedObject var model: AppModel
    let result: SearchIndex.Result
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 9) {
            switch result {
            case .agent(let entry):
                if let resource = BrandIconLoader.agentIcon(for: entry.agent.agent) {
                    BrandIcon(resource: resource, size: 13)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                }
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                AgentStatusGlyph(status: entry.agent.status, unreadDone: model.isUnread(entry))
                Spacer(minLength: 8)
                if entry.agent.status == .blocked {
                    Text("needs input")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                }
                trailing(
                    "\(entry.agent.agent) · \(model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID))",
                    device: entry.device
                )
            case .terminal(let entry):
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing(
                    String(localized: "Terminal · \(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))"),
                    device: entry.device
                )
            case .space(let entry):
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(entry.workspace.label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing(String(localized: "Space · \(model.agentCount(in: entry)) agents"), device: entry.device)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailing(_ text: String, device: Device) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            if model.showsDeviceBadges {
                DeviceChip(device: device)
            }
        }
    }
}
