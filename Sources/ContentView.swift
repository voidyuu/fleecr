import HerdrKit
import SwiftUI
import AppKit

/// Lets us reach the hosting NSWindow to e.g. force a fully transparent title bar
/// (keeps the native toolbar's volume/layout while removing its colour).
struct WindowAccessor: NSViewRepresentable {
    var onUpdate: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onUpdate(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onUpdate(nsView.window) }
    }
}

struct RootView: View {
    @Environment(\.openSettings) private var openSettings
    // Owned by AppDelegate so it outlives the window — see AppDelegate in FleecrApp.swift.
    @ObservedObject var model: AppModel
    // Deliberately not persisted: the app always launches with the sidebar visible.
    @State private var sidebarCollapsed = false
    // Shared by the sidebar's inline filter (⌘K) and the toolbar search field.
    @State private var searchQuery = ""

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AppKitSplitView(
                sidebarCollapsed: $sidebarCollapsed,
                sidebar: AnyView(SidebarView(model: model, query: $searchQuery)),
                detail: AnyView(DetailView(model: model, query: $searchQuery)),
                createSpace: {
                    guard let space = model.currentSpace, let device = model.device(space.deviceID) else { return }
                    model.createNewSpace(on: device)
                }
            )
            .ignoresSafeArea(edges: .top)
        }
        .background(
            Button("") { sidebarCollapsed.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { model.showSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { model.startNewTerminal() }
                .keyboardShortcut("t", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
        )
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            sidebarCollapsed.toggle()
        }
        .focusedSceneValue(\.appModel, model)
        .background(WindowAccessor { window in
            // Distinctive identifier so shortcut handling can tell the main
            // console window apart from e.g. the Settings window.
            window?.identifier = NSUserInterfaceItemIdentifier("fleecr.main")
            window?.titlebarAppearsTransparent = true
            window?.styleMask.insert(.fullSizeContentView)
        })
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 980, minHeight: 620)
        .onAppear {
            model.start()
            ShortcutDispatcher.shared.install(model: model)
        }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet(model: model) }
        .sheet(item: $model.spaceToRename) { entry in renameSpaceSheet(model: model, entry: entry) }
        .sheet(item: $model.agentToRename) { entry in renameAgentSheet(model: model, entry: entry) }
        .sheet(item: $model.terminalToRename) { entry in renameTerminalSheet(model: model, entry: entry) }
        .sheet(item: $model.deviceToEdit) { device in EditDeviceSheet(model: model, device: device) }
        .sheet(item: $model.sshAuthenticationRequest) { request in
            SSHAuthenticationSheet(model: model, request: request)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

}

private struct AppKitSplitView: NSViewControllerRepresentable {
    @Binding var sidebarCollapsed: Bool
    let sidebar: AnyView
    let detail: AnyView
    let createSpace: () -> Void

    func makeNSViewController(context: Context) -> RootSplitViewController {
        RootSplitViewController(sidebar: sidebar, detail: detail)
    }

    func updateNSViewController(_ controller: RootSplitViewController, context: Context) {
        controller.sidebarHost.rootView = sidebar
        controller.detailHost.rootView = detail
        let collapsed = _sidebarCollapsed
        controller.installTitlebarAccessory(
            on: controller.view.window,
            toggleSidebar: { collapsed.wrappedValue.toggle() },
            createSpace: createSpace
        )
        controller.setSidebarCollapsed(sidebarCollapsed)
    }
}

private final class RootSplitViewController: NSSplitViewController {
    let sidebarHost: NSHostingController<AnyView>
    let detailHost: NSHostingController<AnyView>
    let sidebarItem: NSSplitViewItem
    private weak var accessoryWindow: NSWindow?
    private var sidebarAccessory: SidebarTitlebarAccessoryController?
    private var toggleSidebarAction: (() -> Void)?
    private var createSpaceAction: (() -> Void)?
    private var accessoryWidthUpdateScheduled = false
    private var isAnimatingSidebarTransition = false
    private var transitionTargetCollapsed: Bool?
    private var expandedAccessoryWidth: CGFloat?
    private var previousInitialAccessoryWidth: CGFloat?
    private var initialAccessoryLayoutPasses = 0
    private var initialAccessoryLayoutReady = false

    init(sidebar: AnyView, detail: AnyView) {
        let sidebarHost = NSHostingController(rootView: sidebar)
        let detailHost = NSHostingController(rootView: detail)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.preferredThicknessFraction = 260.0 / 980.0
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 380

        self.sidebarHost = sidebarHost
        self.detailHost = detailHost
        self.sidebarItem = sidebarItem
        super.init(nibName: nil, bundle: nil)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: detailHost))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleAccessoryWidthUpdate()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installTitlebarAccessoryIfNeeded()
        view.layoutSubtreeIfNeeded()
        sidebarHost.view.layoutSubtreeIfNeeded()
        updateAccessoryWidth()
    }

    func installTitlebarAccessory(
        on window: NSWindow?,
        toggleSidebar: @escaping () -> Void,
        createSpace: @escaping () -> Void
    ) {
        self.toggleSidebarAction = toggleSidebar
        self.createSpaceAction = createSpace
        installTitlebarAccessoryIfNeeded(on: window)
    }

    private func installTitlebarAccessoryIfNeeded(on window: NSWindow? = nil) {
        guard let window = window ?? view.window,
              accessoryWindow !== window,
              let toggleSidebarAction,
              let createSpaceAction
        else { return }

        let accessory = SidebarTitlebarAccessoryController(
            toggleSidebar: toggleSidebarAction,
            createSpace: createSpaceAction,
            onLayout: { [weak self] in self?.scheduleAccessoryWidthUpdate() }
        )
        accessory.layoutAttribute = .left
        window.addTitlebarAccessoryViewController(accessory)
        sidebarAccessory = accessory
        accessoryWindow = window
        scheduleAccessoryWidthUpdate()
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        if isAnimatingSidebarTransition, transitionTargetCollapsed == collapsed { return }
        guard sidebarItem.isCollapsed != collapsed else { return }
        guard let accessory = sidebarAccessory else {
            toggleSidebar(nil)
            return
        }

        let targetWidth: CGFloat
        if collapsed {
            expandedAccessoryWidth = expandedLayoutWidth(for: accessory)
            targetWidth = accessory.minimumLayoutWidth
        } else {
            targetWidth = expandedAccessoryWidth ?? expandedLayoutWidth(for: accessory)
        }

        isAnimatingSidebarTransition = true
        transitionTargetCollapsed = collapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            accessory.animateSidebarLayoutWidth(targetWidth)
            toggleSidebar(nil)
        } completionHandler: { [weak self] in
            guard let self else { return }
            isAnimatingSidebarTransition = false
            transitionTargetCollapsed = nil
            scheduleAccessoryWidthUpdate()
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        if !isAnimatingSidebarTransition { scheduleAccessoryWidthUpdate() }
    }

    private func scheduleAccessoryWidthUpdate() {
        guard !accessoryWidthUpdateScheduled else { return }
        accessoryWidthUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            accessoryWidthUpdateScheduled = false
            guard !isAnimatingSidebarTransition else { return }
            updateAccessoryWidth()
        }
    }

    private func updateAccessoryWidth() {
        guard accessoryWindow != nil,
              let accessory = sidebarAccessory,
              sidebarHost.view.window === accessory.view.window
        else { return }

        if sidebarItem.isCollapsed {
            applyAccessoryWidth(accessory.minimumLayoutWidth, to: accessory)
            return
        }

        let width = expandedLayoutWidth(for: accessory)
        expandedAccessoryWidth = width
        applyAccessoryWidth(width, to: accessory)
    }

    private func applyAccessoryWidth(_ width: CGFloat, to accessory: SidebarTitlebarAccessoryController) {
        accessory.setSidebarLayoutWidth(width)
        guard !initialAccessoryLayoutReady else { return }

        initialAccessoryLayoutPasses += 1
        if let previousInitialAccessoryWidth,
           abs(previousInitialAccessoryWidth - width) <= 0.5 || initialAccessoryLayoutPasses >= 4 {
            initialAccessoryLayoutReady = true
            accessory.showButtons()
        } else {
            previousInitialAccessoryWidth = width
            scheduleAccessoryWidthUpdate()
        }
    }

    private func expandedLayoutWidth(for accessory: SidebarTitlebarAccessoryController) -> CGFloat {
        let dividerX = sidebarHost.view.convert(
            NSPoint(x: sidebarHost.view.bounds.maxX, y: sidebarHost.view.bounds.midY),
            to: nil
        ).x
        let accessoryX = accessory.view.convert(.zero, to: nil).x
        return max(dividerX - accessoryX, accessory.minimumLayoutWidth)
    }

}

@MainActor
private final class SidebarTitlebarAccessoryController: NSTitlebarAccessoryViewController {
    private let toggleSidebar: () -> Void
    private let createSpace: () -> Void
    private let onLayout: () -> Void
    private let stackTrailingInset: CGFloat = 8
    private var collapsedMinimumWidth: CGFloat = 0

    init(
        toggleSidebar: @escaping () -> Void,
        createSpace: @escaping () -> Void,
        onLayout: @escaping () -> Void
    ) {
        self.toggleSidebar = toggleSidebar
        self.createSpace = createSpace
        self.onLayout = onLayout
        super.init(nibName: nil, bundle: nil)

        let sidebarButton = makeButton("sidebar.left", label: "Toggle sidebar", action: #selector(toggleSidebarAction))
        let spaceButton = makeButton("folder.badge.plus", label: "New Space", action: #selector(createSpaceAction))

        let stack = NSStackView(views: [sidebarButton, spaceButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true

        let accessoryView = NSView()
        accessoryView.addSubview(stack)
        collapsedMinimumWidth = stack.fittingSize.width + stackTrailingInset
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor, constant: -stackTrailingInset),
            stack.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: accessoryView.leadingAnchor)
        ])
        view = accessoryView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout()
    }

    var minimumLayoutWidth: CGFloat { collapsedMinimumWidth }

    func setSidebarLayoutWidth(_ width: CGFloat) {
        guard abs(view.frame.width - width) > 0.5 else { return }
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    func animateSidebarLayoutWidth(_ width: CGFloat) {
        guard abs(view.frame.width - width) > 0.5 else { return }
        view.animator().setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    func showButtons() {
        view.subviews.first?.isHidden = false
    }

    private func makeButton(_ imageName: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: imageName, accessibilityDescription: label)!
        let button = NSButton(image: image, target: self, action: action)
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .circle
        } else {
            button.bezelStyle = .circular
        }
        button.toolTip = label
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 16)
        button.widthAnchor.constraint(equalToConstant: 35).isActive = true
        button.heightAnchor.constraint(equalToConstant: 35).isActive = true
        return button
    }

    @objc private func toggleSidebarAction() { toggleSidebar() }
    @objc private func createSpaceAction() { createSpace() }
}


/// Height of the band the native unified toolbar (52pt) occupies: the detail region reserves
/// it so the terminal never renders under the traffic lights — all toolbar content is native.
enum TitlebarMetrics {
    /// Height of the band the native unified toolbar (52pt) occupies: the detail region reserves
    /// it so the terminal never renders under the traffic lights — all toolbar content is native.
    static let height: CGFloat = 54
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    // Search query shared with the sidebar filter. The toolbar search field writes
    // here; SidebarView reads the same value to filter its rows in place.
    @Binding var query: String
    @State private var searchFieldFocused = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeStore = ThemeStore.shared

    private var activeTerminalTheme: AppTheme {
        let isDark: Bool
        switch themeStore.appearance {
        case .system: isDark = colorScheme == .dark
        case .light: isDark = false
        case .dark: isDark = true
        }
        return isDark ? themeStore.darkTheme : themeStore.lightTheme
    }

    private var terminalBackground: Color {
        Color(hex: activeTerminalTheme.background)
    }

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            detailContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground.ignoresSafeArea())
        // AppKit owns the terminal and search toolbar items so + and search remain adjacent.
        .background(
            NativeToolbarBridge(
                model: model,
                query: $query,
                isSearchPresented: $searchFieldFocused
            )
        )
        // ⌘K (hidden button + global shortcut) asks the model to open search;
        // focus toggling lives here next to the field state it drives.
        .onChange(of: model.showSearch) { _, requested in
            guard requested else { return }
            model.showSearch = false
            searchFieldFocused.toggle()
        }
        // Losing focus (Esc, ⌘K again, clicking a terminal) clears the filter and
        // resets the bar to its placeholder, like a fresh Spotlight open.
        .onChange(of: searchFieldFocused) { _, focused in
            if !focused {
                query = ""
            }
        }
    }

    private var detailContent: some View {
        terminal.clipped()
    }

    // MARK: - Toolbar band

    /// Reserves the unified toolbar band so the terminal never draws under the
    /// traffic lights. Search itself is a native `.searchable` toolbar item, which
    /// macOS places immediately to the left of the New Terminal (+) action.
    private var titlebar: some View {
        terminalBackground
            .frame(height: TitlebarMetrics.height)
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var terminalThinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var terminalFontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var terminalLineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage(TerminalDefaults.mouseReportingKey) private var terminalMouseReporting = TerminalDefaults.defaultMouseReporting
    /// The entry whose attach process exited, and how. Keyed by entry id so a stale
    /// exit from a previously selected pane never covers a live terminal.
    @State private var endedAttachKey: String?
    @State private var endedAttachCode: Int32?
    @State private var attachRetry = 0
    @State private var uploadingAttachment = false

    @ViewBuilder
    private var terminal: some View {
        attachedTerminal
    }

    @ViewBuilder
    private var attachedTerminal: some View {
        if let entry = model.selectedAttachedEntry {
            let attachmentCapabilities: AgentAttachmentCapabilities? = {
                guard case .agent(let agentEntry) = entry else { return nil }
                return model.attachmentCapabilities(
                    deviceID: agentEntry.device.id,
                    agentKind: agentEntry.agent.agentKindRaw
                )
            }()
            ZStack {
                AttachTerminalView(
                    device: entry.device,
                    target: entry.attachTarget,
                    serverVersion: model.serverVersion(deviceID: entry.device.id),
                    attachmentCapabilities: attachmentCapabilities,
                    fontName: terminalFontName,
                    fontSize: terminalFontSize,
                    thinStrokes: terminalThinStrokes,
                    fontWeight: terminalFontWeight,
                    lineSpacing: terminalLineSpacing,
                    theme: activeTerminalTheme,
                    mouseReporting: terminalMouseReporting,
                    onAttachmentError: { model.actionError = $0 },
                    onAttachmentUploadingChanged: { uploadingAttachment = $0 },
                    onExit: { code in
                        endedAttachKey = entry.id
                        endedAttachCode = code
                    }
                )
                .id("attach-\(entry.id)-\(attachRetry)")
                if endedAttachKey == entry.id {
                    attachEndedOverlay(entry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(terminalBackground)
            .overlay(alignment: .bottomTrailing) {
                if uploadingAttachment { uploadIndicator }
            }
            .onChange(of: entry.id) { _, _ in
                endedAttachKey = nil
                uploadingAttachment = false
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textGhost)
                Text(placeholderText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                if model.hasReconnectableDevice {
                    Button("Reconnect") {
                        model.reconnectFailedDevices()
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(terminalBackground)
        }
    }

    /// ssh exits 255 for transport failures; everything else is the far end closing
    /// (takeover by another client, the pane going away, herdr stopping).
    private func attachEndedOverlay(_ entry: AppModel.AttachedEntry) -> some View {
        let dropped = endedAttachCode == 255
        return VStack(spacing: 10) {
            Image(systemName: dropped ? "bolt.horizontal.circle" : "rectangle.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textGhost)
            Text(dropped ? String(localized: "Connection to \(entry.device.name) dropped") : String(localized: "Terminal session ended"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(dropped
                ? String(localized: "The SSH connection behind this terminal went away.")
                : String(localized: "Another client took this pane over, or the attach closed."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Button("Reconnect") {
                endedAttachKey = nil
                attachRetry += 1
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground.opacity(0.94))
    }

    private var uploadIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Uploading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 20)
        .padding(.bottom, 18)
    }

    private var placeholderText: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        default:
            if model.selectedSpace != nil
                && model.visibleAgents.isEmpty
                && model.visibleTerminals.isEmpty {
                return String(localized: "No agents or terminals in this space yet")
            }
            return String(localized: "Select an agent or terminal, or start a new one")
        }
    }

}

struct AddDeviceSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var session = "default"
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: String(localized: "Add Device"),
                subtitle: String(localized: "Runs official 'herdr machine add' to prepare and save the machine")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("remote-server", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("user@host", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Text("user@host, a ~/.ssh/config alias, or user@host:port for a custom port.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer().frame(height: 8)
                SheetSectionLabel("REMOTE SESSION")
                TextField("default", text: $session)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Text("Herdr session name on the remote machine (defaults to \"default\").")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting and preparing remote Herdr server…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .font(.system(size: 12))
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Adding…" : "Add Device") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    let trimmedSession = session.trimmingCharacters(in: .whitespaces)
                    isSubmitting = true
                    errorMessage = nil
                    Task {
                        do {
                            try await model.addDevice(
                                name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                                sshTarget: trimmedTarget,
                                session: trimmedSession.isEmpty ? "default" : trimmedSession
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isSubmitting = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
    }
}

struct SSHAuthenticationSheet: View {
    @ObservedObject var model: AppModel
    let request: SSHAuthenticationRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "key.fill",
                title: String(localized: "SSH Authentication"),
                subtitle: request.target
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("PASSWORD")
                SecureField("SSH password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                Label(String(localized: "Saved in your macOS login Keychain"), systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelSSHAuthentication(for: request)
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.saveSSHPassword(password, for: request)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { passwordFocused = true }
    }
}

/// Shared chrome for the app's sheets: icon-badge header, hairline sections, footer actions.
struct SheetHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct SheetSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// One sheet for every rename: it edits the name herdr itself stores (the
/// workspace or tab label), and the rename goes back through herdr's own
/// `workspace.rename` / `tab.rename` — the same RPCs the herdr TUI uses — so
/// fleecr, the herdr TUI, and `herdr api snapshot` all agree on the name.
@MainActor
private func renameSpaceSheet(model: AppModel, entry: AppModel.SpaceEntry) -> some View {
    RenameItemSheet(
        title: String(localized: "Rename Space"),
        subtitle: String(localized: "Rename \(entry.workspace.label) on \(entry.device.name)"),
        placeholder: String(localized: "Space name"),
        hint: nil,
        seed: entry.workspace.label
    ) { name in
        model.renameSpace(entry, label: name)
    }
}

@MainActor
private func renameAgentSheet(model: AppModel, entry: AppModel.AgentEntry) -> some View {
    RenameItemSheet(
        title: String(localized: "Rename Agent"),
        subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)"),
        placeholder: entry.title,
        hint: String(localized: "Chinese, spaces, and punctuation are allowed."),
        seed: entry.tabName
    ) { name in
        model.renameAgent(entry, name: name)
    }
}

@MainActor
private func renameTerminalSheet(model: AppModel, entry: AppModel.TerminalEntry) -> some View {
    RenameItemSheet(
        title: String(localized: "Rename Terminal"),
        subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)"),
        placeholder: entry.title,
        hint: String(localized: "Chinese, spaces, and punctuation are allowed."),
        seed: entry.tab?.renameSeed(agentKind: nil)
    ) { name in
        model.renameTerminal(entry, name: name)
    }
}

/// Edits one backend-owned name. `seed` is the name herdr currently stores;
/// renaming to it is a no-op, so the button disables itself.
struct RenameItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    let title: String
    let subtitle: String
    let placeholder: String
    let hint: String?
    let seed: String?
    let perform: (String) -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(systemImage: "pencil", title: title, subtitle: subtitle)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField(placeholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    perform(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == seed)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { name = seed ?? "" }
    }
}

struct EditDeviceSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var session = "default"
    @State private var isEnabled = true
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Edit Device"),
                subtitle: String(localized: "Applies changes via official 'herdr machine' CLI")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("SSH target", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Spacer().frame(height: 8)
                SheetSectionLabel("REMOTE SESSION")
                TextField("default", text: $session)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Spacer().frame(height: 8)
                Toggle("Enabled", isOn: $isEnabled)
                    .font(.system(size: 12.5))
                    .disabled(isSubmitting)
            }
            .padding(16)

            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying changes via herdr CLI…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .font(.system(size: 12))
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Saving…" : "Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    let trimmedSession = session.trimmingCharacters(in: .whitespaces)
                    isSubmitting = true
                    errorMessage = nil
                    Task {
                        do {
                            try await model.updateDevice(
                                device.id,
                                name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                                sshTarget: trimmedTarget,
                                session: trimmedSession.isEmpty ? "default" : trimmedSession,
                                isEnabled: isEnabled
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isSubmitting = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .onAppear {
            name = device.name
            target = device.sshTarget ?? ""
            session = device.session
            isEnabled = device.isEnabled
        }
    }
}
