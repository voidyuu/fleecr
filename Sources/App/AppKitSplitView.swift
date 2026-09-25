import SwiftUI
import AppKit

/// Lets us reach the hosting NSWindow so content can extend beneath the titlebar
/// toolbar.
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

struct AppKitSplitView: NSViewControllerRepresentable {
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

final class RootSplitViewController: NSSplitViewController {
    private static let sidebarWidthKey = "FleecrMainSidebarWidth"

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
    private var restoredSidebarWidth = false

    init(sidebar: AnyView, detail: AnyView) {
        let sidebarHost = NSHostingController(rootView: sidebar)
        let detailHost = NSHostingController(rootView: detail)
        // Let the terminal render underneath the transparent titlebar toolbar.
        detailHost.safeAreaRegions = []
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
        if !restoredSidebarWidth {
            restoredSidebarWidth = true
            if UserDefaults.standard.object(forKey: Self.sidebarWidthKey) != nil {
                let savedWidth = CGFloat(UserDefaults.standard.double(forKey: Self.sidebarWidthKey))
                splitView.setPosition(
                    min(max(savedWidth, sidebarItem.minimumThickness), sidebarItem.maximumThickness),
                    ofDividerAt: 0
                )
                view.layoutSubtreeIfNeeded()
            }
        }
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
            context.allowsImplicitAnimation = true
            accessory.animateSidebarButtons(collapsed: collapsed, expandedWidth: expandedAccessoryWidth ?? targetWidth)
            toggleSidebar(nil)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if collapsed { accessory.setSidebarLayoutWidth(targetWidth) }
                isAnimatingSidebarTransition = false
                transitionTargetCollapsed = nil
                scheduleAccessoryWidthUpdate()
            }
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        if restoredSidebarWidth, !sidebarItem.isCollapsed {
            let width = sidebarHost.view.frame.width
            if width >= sidebarItem.minimumThickness, width <= sidebarItem.maximumThickness {
                UserDefaults.standard.set(width, forKey: Self.sidebarWidthKey)
            }
        }
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
    private var stackWidth: CGFloat = 0
    private var stackLeadingConstraint: NSLayoutConstraint!
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

        let stack = NSStackView(views: [spaceButton, sidebarButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stackWidth = stack.fittingSize.width
        stack.isHidden = true

        let accessoryView = NSView()
        accessoryView.addSubview(stack)
        collapsedMinimumWidth = stackWidth + stackTrailingInset
        stackLeadingConstraint = stack.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor)
        NSLayoutConstraint.activate([
            stackLeadingConstraint,
            stack.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
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
        if abs(view.frame.width - width) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }
        stackLeadingConstraint.constant = max(0, width - stackWidth - stackTrailingInset)
    }

    func animateSidebarButtons(collapsed: Bool, expandedWidth: CGFloat) {
        if abs(view.frame.width - expandedWidth) > 0.5 {
            view.setFrameSize(NSSize(width: expandedWidth, height: view.frame.height))
        }
        stackLeadingConstraint.animator().constant = collapsed
            ? 0
            : max(0, expandedWidth - stackWidth - stackTrailingInset)
        view.layoutSubtreeIfNeeded()
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
