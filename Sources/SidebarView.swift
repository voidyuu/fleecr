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
            // 28pt titlebar strip: traffic lights on the left, collapse toggle on the right
            HStack {
                Spacer()
                TitlebarIconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘B)") {
                    collapsed = true
                }
            }
            .padding(.horizontal, 10)
            .frame(height: TitlebarMetrics.height)

            Spacer().frame(height: 8)

            VStack(spacing: 1) {
                // Persistent Herdr terminals are listed under TERMINALS below.
                actionRow(icon: "terminal", label: "New Terminal") {
                    model.startNewTerminal()
                }
                actionRow(icon: "magnifyingglass", label: "Search") {
                    model.showSearch = true
                }
            }
            .padding(.horizontal, 10)

            Spacer().frame(height: 10)

            ScrollView {
                VStack(spacing: 1) {
                    // Title + chevron used to be a decorative HStack with no
                    // tap target, so the chevron promised a disclosure that
                    // never fired. The trailing menu does not toggle the section.
                    groupHeader("Spaces", expanded: $spacesExpanded) {
                        Group {
                            if model.devices.count == 1, let device = model.devices.first {
                                Button { model.createNewSpace(on: device) } label: {
                                    Image(systemName: "folder.badge.plus")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textGhost)
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                            } else {
                                Menu {
                                    ForEach(model.devices) { device in
                                        Button(device.name) { model.createNewSpace(on: device) }
                                    }
                                } label: {
                                    Image(systemName: "folder.badge.plus")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textGhost)
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("New Space")
                        .focusEffectDisabled()
                    }
                    if spacesExpanded {
                        ForEach(model.visibleSpaces) { entry in
                            SpaceRowView(
                                entry: entry,
                                model: model,
                                draggingSpaceID: $draggingSpaceID,
                                spaceDrop: $spaceDrop
                            )
                        }
                    }

                    Spacer().frame(height: 10)

                    groupHeader("Agents", expanded: $agentsExpanded)
                    if agentsExpanded {
                        if model.visibleAgents.isEmpty {
                            Text(emptyAgentsHint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textGhost)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        ForEach(model.visibleAgents) { entry in
                            AgentRowView(
                                entry: entry,
                                model: model,
                                draggingAgentID: $draggingAgentID,
                                agentDrop: $agentDrop
                            )
                        }
                    }

                    if !model.visibleTerminals.isEmpty {
                        Spacer().frame(height: 10)
                        groupHeader("Terminals", expanded: $terminalsExpanded)
                        if terminalsExpanded {
                            ForEach(model.visibleTerminals) { entry in
                                terminalRow(entry)
                                    .contextMenu {
                                        Button("Rename Terminal…") { model.terminalToRename = entry }
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
        .frame(width: 260)
        .background(Theme.sidebarBackground(theme: themeStore.activeTheme).ignoresSafeArea())
    }

    private var emptyAgentsHint: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        default: return String(localized: "No agents")
        }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    private struct AgentRowView: View {
    let entry: AppModel.AgentEntry
    @ObservedObject var model: AppModel
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

    // MARK: - Footer (status & settings)

    private var footer: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionDotColor)
                .frame(width: 6, height: 6)
            Text(connectionStatusText)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var connectionStatusText: String {
        switch model.connection {
        case .connected: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        case .idle: return String(localized: "Idle")
        }
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

/// Small icon button that sits in the 28pt titlebar strip.
struct TitlebarIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? AnyShapeStyle(Theme.itemWash) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
