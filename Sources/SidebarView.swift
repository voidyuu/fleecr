import AppKit
import HerdrKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var collapsed: Bool
    // Shared toolbar search (⌘K): an active query hides non-matching rows in place.
    @Binding var query: String
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var draggingSpaceID: String?
    @State private var spaceDrop: (id: String, after: Bool)?
    @State private var draggingAgentID: String?
    @State private var agentDrop: (id: String, after: Bool)?
    @State private var spacesExpanded = true
    @State private var agentsExpanded = true
    @State private var terminalsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 10)

            ScrollView {
                VStack(spacing: 1) {
                    // While searching the sidebar drops the Spaces section entirely
                    // and flattens all matching agents/terminals from every space.
                    if !filtering {
                        groupHeader("Spaces", expanded: $spacesExpanded)
                        if spacesExpanded {
                            ForEach(displaySpaces) { entry in
                                SpaceRowView(
                                    entry: entry,
                                    model: model,
                                    draggingSpaceID: $draggingSpaceID,
                                    spaceDrop: $spaceDrop
                                )
                            }
                        }

                        Spacer().frame(height: 10)
                    }

                    // In sync with the Terminals group: when there are no matching
                    // agents the whole section hides instead of showing an empty
                    // header (and, while filtering, a "No matches" line).
                    if !displayAgents.isEmpty {
                        groupHeader("Agents", expanded: $agentsExpanded)
                        if agentsExpanded {
                            ForEach(displayAgents) { entry in
                                AgentRowView(
                                    entry: entry,
                                    model: model,
                                    hideSpace: filtering,
                                    draggingAgentID: $draggingAgentID,
                                    agentDrop: $agentDrop
                                )
                            }
                        }
                    }

                    if !displayTerminals.isEmpty {
                        Spacer().frame(height: 10)
                        groupHeader("Terminals", expanded: $terminalsExpanded)
                        if terminalsExpanded {
                            ForEach(displayTerminals) { entry in
                                terminalRow(entry)
                                    .contextMenu {
                                        Button(String(localized: "Rename Terminal…")) { model.terminalToRename = entry }
                                        Button("Close Terminal…", role: .destructive) {
                                            model.requestClosePane(entry.ref, name: entry.title)
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 48)
        .frame(width: 260)
        .background(Theme.sidebarBackground(theme: themeStore.activeTheme).ignoresSafeArea())
    }

    // Filtered rows: layout/group order is unchanged; an empty query (no filter)
    // is the identity, a non-empty query keeps only what matches.
    private var filtering: Bool { SidebarSearch.isActive(query) }
    /// Spaces are only shown outside a search; while searching the sidebar flattens
    /// to just Agents + Terminals (spaces are no longer a grouping concept).
    private var displaySpaces: [AppModel.SpaceEntry] { model.visibleSpaces }
    private var displayAgents: [AppModel.AgentEntry] {
        SidebarSearch.matchingAgents(model: model, query: query)
    }
    private var displayTerminals: [AppModel.TerminalEntry] {
        SidebarSearch.matchingTerminals(model: model, query: query)
    }

    // MARK: - Rows

    private func actionRow(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        // CSS `outline: none` is not a SwiftUI concept. This is the native
        // equivalent for chrome (New Terminal / Search). List
        // rows keep their focus ring for keyboard access.
        .focusEffectDisabled()
    }

    private func groupHeader(_ title: LocalizedStringKey, expanded: Binding<Bool>) -> some View {
        groupHeader(title, expanded: expanded) { EmptyView() }
    }

    private func groupHeader<Trailing: View>(
        _ title: LocalizedStringKey,
        expanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .disclosureAccessibility(expanded: expanded.wrappedValue)

            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }


    private func terminalRow(_ entry: AppModel.TerminalEntry) -> some View {
        let selected = model.selectedPane == entry.ref
        return Button {
            model.selectAgent(entry.ref)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Text(entry.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(height: 51)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    private struct AgentRowView: View {
    let entry: AppModel.AgentEntry
    @ObservedObject var model: AppModel
    var hideSpace: Bool = false
    @Binding var draggingAgentID: String?
    @Binding var agentDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let agent = entry.agent
        let selected = model.selectedPane == entry.ref
        let unread = model.isUnread(entry)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                AgentStatusGlyph(status: agent.status, unreadDone: unread)
            }
            if hideSpace {
                HStack(spacing: 5) {
                    AgentKindBadge(kind: agent.agent)
                    Spacer(minLength: 0)
                    if agent.status == .blocked {
                        Text("needs input")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.warning)
                    }
                }
            } else {
                HStack(spacing: 5) {
                    AgentKindBadge(kind: agent.agent)
                    Text("·")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textGhost)
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if agent.status == .blocked {
                        Text("needs input")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(height: 51)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
        .opacity(draggingAgentID == entry.id ? 0.4 : 1)
        .overlay(alignment: (agentDrop?.after ?? false) ? .bottom : .top) {
            if agentDrop?.id == entry.id {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 2)
            }
        }
        .overlay {
            AgentRowDragHost(
                entryID: entry.id,
                onClick: { model.selectAgent(entry.ref) },
                onRename: { model.agentToRename = entry },
                onClose: { model.requestClosePane(entry.ref, name: entry.title) },
                onDragStart: { draggingAgentID = $0 },
                onDragEnd: {
                    draggingAgentID = nil
                    agentDrop = nil
                },
                onDropHover: { after in agentDrop = (entry.id, after) },
                onHoverExit: {
                    if agentDrop?.id == entry.id { agentDrop = nil }
                },
                onDrop: { sourceID, after in
                    draggingAgentID = nil
                    agentDrop = nil
                    guard let source = model.visibleAgents.first(where: { $0.id == sourceID })
                    else { return }
                    model.moveAgent(source, onto: entry, placeAfter: after)
                }
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel(unread: unread))
    }

    private func accessibilityLabel(unread: Bool) -> String {
        var parts = [entry.title]
        switch entry.agent.status {
        case .working: parts.append(String(localized: "Working"))
        case .blocked: parts.append(String(localized: "Needs input"))
        case .done where unread: parts.append(String(localized: "Unread"))
        case .done: break
        case .idle, .unknown: break
        }
        return parts.joined(separator: ", ")
    }
}

    // MARK: - Footer (connection status)

    private var footer: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionDotColor)
                .frame(width: 6, height: 6)

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var connectionDotColor: Color {
        switch model.connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }
}

/// Native-looking icon toggle button that sits in the edge-to-edge 28pt title strip.
/// It has no background fill, so there is never a separate coloured band behind it.
struct SidebarToggleButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: TitlebarMetrics.height)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(help)
    }
}

private extension View {
    /// Button trait plus expanded/collapsed so VoiceOver matches the chevron.
    /// macOS SwiftUI has no `accessibilityExpanded`; VoiceOver reads the value.
    func disclosureAccessibility(expanded: Bool) -> some View {
        self
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || configuration.isPressed ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
    }
}

/// Not a `Button`: on macOS, `Button` consumes mouseDown so SwiftUI `.onDrag`
/// never starts. Click and reorder go through `SpaceRowDragHost`.
private struct SpaceRowView: View {
    let entry: AppModel.SpaceEntry
    @ObservedObject var model: AppModel
    @Binding var draggingSpaceID: String?
    @Binding var spaceDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let selected = model.selectedSpace == entry.ref
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
            Text(entry.workspace.label)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            SpaceAttentionGlyph(attention: model.attention(in: entry))
            if model.showsRowDeviceBadges {
                DeviceChip(device: entry.device)
            }
            Text("\(model.agentCount(in: entry))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textGhost)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
        .opacity(draggingSpaceID == entry.id ? 0.4 : 1)
        .overlay(alignment: (spaceDrop?.after ?? false) ? .bottom : .top) {
            if spaceDrop?.id == entry.id {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 2)
            }
        }
        .overlay {
            SpaceRowDragHost(
                entryID: entry.id,
                label: entry.workspace.label,
                onClick: { model.selectSpace(entry.ref) },
                onRename: { model.spaceToRename = entry },
                onClose: { model.requestCloseSpace(entry) },
                onDragStart: { draggingSpaceID = $0 },
                onDragEnd: {
                    draggingSpaceID = nil
                    spaceDrop = nil
                },
                onDropHover: { after in spaceDrop = (entry.id, after) },
                onHoverExit: {
                    if spaceDrop?.id == entry.id { spaceDrop = nil }
                },
                onDrop: { sourceID, after in
                    draggingSpaceID = nil
                    spaceDrop = nil
                    guard let source = model.visibleSpaces.first(where: { $0.id == sourceID })
                    else { return }
                    model.moveSpace(source, onto: entry, placeAfter: after)
                }
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [entry.workspace.label]
        switch model.attention(in: entry) {
        case .blocked: parts.append(String(localized: "Needs input"))
        case .unreadDone: parts.append(String(localized: "Unread"))
        case .working: parts.append(String(localized: "Working"))
        case .none: break
        }
        return parts.joined(separator: ", ")
    }
}

struct SpinnerView: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
