import AppKit
import GhosttyKit
import GhosttyTerminal
import HerdrKit
import SwiftUI
import UniformTypeIdentifiers

enum TerminalDefaults {
    static let fontNameKey = "terminal.fontName"   // "" = system monospaced
    static let fontSizeKey = "terminal.fontSize"
    static let thinStrokesKey = "terminal.thinStrokes"
    static let fontWeightKey = "terminal.fontWeight"
    static let lineSpacingKey = "terminal.lineSpacing"
    static let mouseReportingKey = "terminal.mouseReporting"
    static let defaultFontSize: Double = 12.5
    /// `NSFont.Weight` rawValue; 0 is `.regular`. Only the system monospaced font
    /// has selectable weights — named families ship fixed faces and ignore this.
    static let defaultFontWeight: Double = 0
    static let defaultLineSpacing: Double = 1.0
    static let defaultMouseReporting: Bool = false
    static let defaultPaddingX: Int = 8
    static let defaultPaddingY: Int = 6
    static let darkBackground = NSColor(
        srgbRed: 0x10 / 255,
        green: 0x10 / 255,
        blue: 0x12 / 255,
        alpha: 1
    )
    static let darkForeground = NSColor(
        srgbRed: 0xD6 / 255,
        green: 0xD6 / 255,
        blue: 0xD6 / 255,
        alpha: 1
    )
    static let lightBackground = NSColor.white
    static let lightForeground = NSColor(
        srgbRed: 0x3A / 255,
        green: 0x3A / 255,
        blue: 0x3A / 255,
        alpha: 1
    )

    static let darkHexBackground = "#101012"
    static let darkHexForeground = "#d6d6d6"
    static let lightHexBackground = "#ffffff"
    static let lightHexForeground = "#3a3a3a"

    // Default ANSI 16 palette for dark mode (Terminal.app style)
    static let darkHexPalette: [String] = [
        "#000000", "#c91b00", "#00c200", "#c7c400", "#0225c7", "#ca30c7", "#00c5c7", "#c7c7c7",
        "#676767", "#ff6d67", "#5ff967", "#fefb67", "#6871ff", "#ff76ff", "#5ffdff", "#feffff"
    ]

    // Luminance-adjusted ANSI 16 palette for light background
    static let lightHexPalette: [String] = {
        darkHexPalette.map { hex in
            guard hex.hasPrefix("#"), hex.count == 7,
                  let r = Int(hex.dropFirst(1).prefix(2), radix: 16),
                  let g = Int(hex.dropFirst(3).prefix(2), radix: 16),
                  let b = Int(hex.dropFirst(5).prefix(2), radix: 16)
            else { return hex }
            let flipped = LightTerminalANSIAdapter.lightRGB(red: r, green: g, blue: b)
            let originalContrast = LightTerminalANSIAdapter.contrastOnWhite(red: r, green: g, blue: b)
            let flippedContrast = LightTerminalANSIAdapter.contrastOnWhite(red: flipped.red, green: flipped.green, blue: flipped.blue)
            let chosen = originalContrast >= flippedContrast ? (r, g, b) : flipped
            return String(format: "#%02x%02x%02x", chosen.0, chosen.1, chosen.2)
        }
    }()

    /// Bundled Nerd Font symbols (MIT, github.com/ryanoasis/nerd-fonts), used
    /// as a fallback for the icon glyphs agent TUIs draw.
    static let symbolFallbackFamily = "Symbols Nerd Font Mono"

    /// Registers the bundled symbols font for this process. Call once at launch.
    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(name: String, size: Double, weight: Double = defaultFontWeight) -> NSFont {
        let base: NSFont
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            base = custom
        } else {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: NSFont.Weight(weight))
        }
        return withSymbolFallback(base, size: size)
    }

    /// Nerd Font icons live in Unicode's Private Use Area, which CoreText's
    /// default cascade never resolves — agent TUIs like pi's powerfooter came
    /// out as tofu boxes unless the user's chosen terminal font happened to be
    /// a patched Nerd Font. A cascade entry pointing at the bundled symbols
    /// font resolves PUA glyphs for every terminal font; the system cascade
    /// still runs after it, so emoji and CJK fallback stay untouched.
    private static func withSymbolFallback(_ base: NSFont, size: Double) -> NSFont {
        let fallback = NSFontDescriptor(fontAttributes: [.family: symbolFallbackFamily])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Fixed-pitch font families available on this Mac, for the settings picker.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
}

private struct ClipboardFile: Sendable {
    let localURL: URL
    let removeAfterUpload: Bool
}

private struct PendingAttachmentPaste: Sendable {
    let files: [ClipboardFile]
    let pathSyntax: AgentAttachmentPathSyntax
}

private enum ClipboardFileError: LocalizedError {
    case unsupportedItem
    case imageEncodingFailed
    case transferUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedItem: return String(localized: "Remote paste supports regular files, not folders or special files.")
        case .imageEncodingFailed: return String(localized: "The clipboard image could not be encoded as PNG.")
        case .transferUnavailable: return String(localized: "The remote file transfer service is unavailable.")
        }
    }
}

@MainActor
protocol LocalProcessTerminalViewDelegate: AnyObject {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: LocalProcessTerminalView, title: String)
    func hostCurrentDirectoryUpdate(source: LocalProcessTerminalView, directory: String?)
    func processTerminated(source: LocalProcessTerminalView, exitCode: Int32?)
}

typealias LocalProcessTerminalView = LineBreakTerminalView

/// Ghostty-backed terminal view supporting line break on Shift+Return,
/// Mac editing shortcuts, file/image paste, and local PTY process execution.
final class LineBreakTerminalView: AppTerminalView {
    let inMemorySession: InMemoryTerminalSession
    let terminalController: TerminalController
    var process: LocalPTYProcess?

    var usesLightColors = false
    var appliedDarkAppearance: Bool?
    private var lightColorAdapter = LightTerminalANSIAdapter()
    var optionAsMetaKey = true
    var bracketedPasteMode = false
    var mouseReporting = TerminalDefaults.defaultMouseReporting

    weak var processDelegate: LocalProcessTerminalViewDelegate?

    var attachmentCapabilities: AgentAttachmentCapabilities?
    var attachmentDeviceKind: Device.Kind = .local
    var attachmentService: HerdrService?
    var onAttachmentError: ((String) -> Void)?
    var onAttachmentUploadingChanged: ((Bool) -> Void)?
    private var pendingUploads: [PendingAttachmentPaste] = []
    private var uploadTask: Task<Void, Never>?
    private var dragStartPoint: (x: Double, y: Double)?
    private var hasStartedDrag: Bool = false
    private var suppressProcessOutput: Bool = false

    init(controller: TerminalController, session: InMemoryTerminalSession) {
        self.terminalController = controller
        self.inMemorySession = session
        super.init(frame: .zero)
        self.controller = controller
        self.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        self.delegate = self
    }

    convenience init() {
        weak var weakSelf: LineBreakTerminalView?

        let session = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in
                    guard let weakSelf, !weakSelf.suppressProcessOutput else { return }
                    weakSelf.process?.send(data)
                }
            },
            resize: { viewport in
                Task { @MainActor in
                    weakSelf?.process?.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
                    if let ws = weakSelf {
                        ws.processDelegate?.sizeChanged(source: ws, newCols: Int(viewport.columns), newRows: Int(viewport.rows))
                    }
                }
            }
        )

        let controller = TerminalController()
        self.init(controller: controller, session: session)
        weakSelf = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        uploadTask?.cancel()
    }

    func resetLightColorAdapter() {
        lightColorAdapter = LightTerminalANSIAdapter()
    }

    func startProcess(
        executable: String,
        args: [String],
        environment: [String: String],
        workingDirectory: String? = nil
    ) {
        let pty = LocalPTYProcess()
        pty.onOutput = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if self.usesLightColors {
                    let transformed = self.lightColorAdapter.transform(Array(data)[...])
                    if !transformed.isEmpty {
                        self.inMemorySession.receive(Data(transformed))
                    }
                } else {
                    self.inMemorySession.receive(data)
                }
            }
        }
        pty.onExit = { [weak self] exitCode in
            Task { @MainActor in
                guard let self else { return }
                self.inMemorySession.finish(exitCode: UInt32(bitPattern: exitCode), runtimeMilliseconds: 0)
                self.processDelegate?.processTerminated(source: self, exitCode: exitCode)
            }
        }

        self.process = pty
        do {
            try pty.start(
                executable: executable,
                args: args,
                environment: environment,
                workingDirectory: workingDirectory
            )
        } catch {
            NSLog("Failed to start LocalPTYProcess: \(error)")
        }
    }

    func terminate(signal: Int32 = SIGHUP) {
        process?.terminate(signal: signal)
        process = nil
    }

    func send(txt: String) {
        process?.send(Data(txt.utf8))
    }

    func send(source: Any?, data: ArraySlice<UInt8>) {
        process?.send(Data(data))
    }

    func feed(byteArray: ArraySlice<UInt8>) {
        inMemorySession.receive(Data(byteArray))
    }

    private func terminalMousePoint(from event: NSEvent) -> (x: Double, y: Double) {
        let point = convert(event.locationInWindow, from: nil)
        return (Double(point.x), Double(bounds.height - point.y))
    }

    func clearSelection(at point: (x: Double, y: Double)? = nil) {
        guard surface?.hasSelection() == true else { return }
        suppressProcessOutput = true
        defer { suppressProcessOutput = false }
        if let point {
            sendMousePos(x: point.x, y: point.y, modifiers: [])
        }
        sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: [])
        sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: [])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = terminalMousePoint(from: event)
        let isShiftDown = event.modifierFlags.contains(.shift)

        // If mouse reporting is disabled and the application captured the mouse (e.g. Claude Code),
        // manage selection locally so that dragging selects text and clicking clears selection,
        // without trapping Ghostty in Shift-extend mode.
        if !mouseReporting && isMouseCaptured {
            dragStartPoint = point
            hasStartedDrag = false

            if !isShiftDown && surface?.hasSelection() == true {
                clearSelection(at: point)
            }

            if event.clickCount > 1 || isShiftDown {
                let mods: TerminalInputModifiers = [.shift]
                sendMousePos(x: point.x, y: point.y, modifiers: mods)
                sendMouseButton(
                    state: GHOSTTY_MOUSE_PRESS,
                    button: GHOSTTY_MOUSE_LEFT,
                    modifiers: mods
                )
            }
            return
        }

        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if !mouseReporting && isMouseCaptured {
            let point = terminalMousePoint(from: event)
            let mods: TerminalInputModifiers = [.shift]

            if !hasStartedDrag {
                hasStartedDrag = true
                let start = dragStartPoint ?? point
                sendMousePos(x: start.x, y: start.y, modifiers: mods)
                sendMouseButton(
                    state: GHOSTTY_MOUSE_PRESS,
                    button: GHOSTTY_MOUSE_LEFT,
                    modifiers: mods
                )
            }

            sendMousePos(x: point.x, y: point.y, modifiers: mods)
            return
        }

        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !mouseReporting && isMouseCaptured {
            let point = terminalMousePoint(from: event)
            let isShiftDown = event.modifierFlags.contains(.shift)

            if hasStartedDrag {
                let mods: TerminalInputModifiers = [.shift]
                sendMousePos(x: point.x, y: point.y, modifiers: mods)
                sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: GHOSTTY_MOUSE_LEFT,
                    modifiers: mods
                )
            } else if event.clickCount > 1 || isShiftDown {
                let mods: TerminalInputModifiers = [.shift]
                sendMousePos(x: point.x, y: point.y, modifiers: mods)
                sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: GHOSTTY_MOUSE_LEFT,
                    modifiers: mods
                )
            }

            dragStartPoint = nil
            hasStartedDrag = false
            return
        }

        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && surface?.hasSelection() == true {
            clearSelection()
        }
        if !hasMarkedText(), let payload = ptyBytes(forMacEditingKey: event) {
            send(txt: payload)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command && event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Mac Delete is Backspace (keyCode 51). ⌥⌘ arrows move split focus and
    /// are left alone; ⌘A/⌘E/⌘W and the other app chords never match here.
    private func ptyBytes(forMacEditingKey event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = modifiers.contains(.command)
            && modifiers.isDisjoint(with: [.option, .control])
        let optionOnly = optionAsMetaKey
            && modifiers.contains(.option)
            && modifiers.isDisjoint(with: [.command, .control])

        if commandOnly {
            switch event.keyCode {
            case 51:  return "\u{15}"  // ⌘⌫ → ^U
            case 123: return "\u{01}"  // ⌘← → ^A
            case 124: return "\u{05}"  // ⌘→ → ^E
            case 117: return "\u{0b}"  // ⌘⌦ → ^K
            default: break
            }
        }
        if optionOnly {
            switch event.keyCode {
            case 51:  return "\u{1b}\u{7f}"  // ⌥⌫ → ESC DEL
            case 123: return "\u{1b}b"       // ⌥← → ESC b
            case 124: return "\u{1b}f"       // ⌥→ → ESC f
            case 117: return "\u{1b}d"       // ⌥⌦ → ESC d
            default: break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76,  // Return, keypad Enter
           modifiers.contains(.shift),
           modifiers.isDisjoint(with: [.command, .control, .option]) {
            return "\u{1b}\r"
        }
        return nil
    }

    override func selectionContextMenu() -> NSMenu {
        let menu = NSMenu()
        let selectedText = surface?.readSelection() ?? ""
        if !selectedText.isEmpty {
            menu.addItem(makeItem(String(localized: "Copy"), #selector(copy(_:))))
            if let url = Self.firstURL(in: selectedText) {
                menu.addItem(.separator())
                let open = makeItem(String(localized: "Open Link"), #selector(openLinkFromMenu(_:)))
                open.representedObject = url
                menu.addItem(open)
                let copyLink = makeItem(String(localized: "Copy Link Address"), #selector(copyLinkFromMenu(_:)))
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
            menu.addItem(.separator())
        }
        menu.addItem(makeItem(String(localized: "Paste"), #selector(paste(_:))))
        menu.addItem(makeItem(String(localized: "Select All"), #selector(selectAll(_:))))
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        selectionContextMenu()
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector?.firstMatch(in: text, range: range),
              let url = match.url,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let fileURLs = Self.fileURLs(in: pasteboard), !fileURLs.isEmpty {
            let action = AgentAttachmentDeliveryPolicy.action(
                capabilities: attachmentCapabilities,
                deviceKind: attachmentDeviceKind,
                source: .files(allImages: fileURLs.allSatisfy(Self.isImageFile))
            )
            handleFilePaste(action: action, fileURLs: fileURLs, sender: sender)
            return
        }

        guard Self.containsImageData(in: pasteboard) else {
            super.paste(sender)
            return
        }

        let action = AgentAttachmentDeliveryPolicy.action(
            capabilities: attachmentCapabilities,
            deviceKind: attachmentDeviceKind,
            source: .imageData
        )
        switch action {
        case .unsupported:
            super.paste(sender)
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            do {
                guard let files = try Self.clipboardFiles(in: pasteboard) else {
                    super.paste(sender)
                    return
                }
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    private func handleFilePaste(
        action: AgentAttachmentDeliveryAction,
        fileURLs: [URL],
        sender: Any?
    ) {
        switch action {
        case .unsupported:
            super.paste(sender)
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            if case .local = attachmentDeviceKind {
                sendPastedText(fileURLs.map { pathSyntax.format($0.path) }.joined(separator: " "))
                return
            }
            do {
                let files = try Self.clipboardFiles(from: fileURLs)
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    private func forwardNativeClipboardPaste() {
        guard let controlV = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ) else {
            let bytes: [UInt8] = [0x16]
            process?.send(Data(bytes))
            return
        }
        keyDown(with: controlV)
    }

    private func enqueuePathPaste(
        _ files: [ClipboardFile],
        pathSyntax: AgentAttachmentPathSyntax
    ) {
        guard let attachmentService else {
            discardTemporaries(in: files)
            reportAttachmentError(ClipboardFileError.transferUnavailable)
            return
        }
        pendingUploads.append(PendingAttachmentPaste(files: files, pathSyntax: pathSyntax))
        guard uploadTask == nil else { return }
        onAttachmentUploadingChanged?(true)
        uploadTask = Task { [weak self] in
            await self?.drainPathPastes(using: attachmentService)
        }
    }

    @MainActor
    private func drainPathPastes(using service: HerdrService) async {
        while !pendingUploads.isEmpty {
            let paste = pendingUploads.removeFirst()
            let files = paste.files
            defer { discardTemporaries(in: files) }
            do {
                var devicePaths: [String] = []
                for file in files {
                    try Task.checkCancellation()
                    devicePaths.append(try await service.stageAttachment(from: file.localURL))
                }
                try Task.checkCancellation()
                sendPastedText(devicePaths.map(paste.pathSyntax.format).joined(separator: " "))
            } catch is CancellationError {
                break
            } catch {
                reportAttachmentError(error)
            }
        }
        pendingUploads.forEach { discardTemporaries(in: $0.files) }
        pendingUploads.removeAll()
        uploadTask = nil
        onAttachmentUploadingChanged?(false)
    }

    private func discardTemporaries(in files: [ClipboardFile]) {
        for file in files where file.removeAfterUpload {
            try? FileManager.default.removeItem(at: file.localURL)
        }
    }

    private func sendPastedText(_ text: String) {
        if !paste(text: text) {
            process?.send(Data(text.utf8))
        }
    }

    private func reportAttachmentError(_ error: Error) {
        onAttachmentError?(error.localizedDescription)
    }

    private static func clipboardFiles(in pasteboard: NSPasteboard) throws -> [ClipboardFile]? {
        if let fileURLs = fileURLs(in: pasteboard), !fileURLs.isEmpty {
            return try clipboardFiles(from: fileURLs)
        }

        guard !hasText(in: pasteboard),
              let image = pasteboard.readObjects(
                  forClasses: [NSImage.self],
                  options: nil
              )?.first as? NSImage
        else {
            return nil
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw ClipboardFileError.imageEncodingFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-clipboard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let localURL = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
        try png.write(to: localURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: localURL.path
        )
        return [ClipboardFile(localURL: localURL, removeAfterUpload: true)]
    }

    private static func clipboardFiles(from fileURLs: [URL]) throws -> [ClipboardFile] {
        try fileURLs.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ClipboardFileError.unsupportedItem
            }
            return ClipboardFile(localURL: url, removeAfterUpload: false)
        }
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private static func containsImageData(in pasteboard: NSPasteboard) -> Bool {
        !hasText(in: pasteboard)
            && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = values.contentType
        else { return false }
        return contentType.conforms(to: .image)
    }

    private static func hasText(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSString.self], options: nil)
    }
}

extension LineBreakTerminalView: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        guard let targetURL = URL(string: url),
              targetURL.scheme == "http" || targetURL.scheme == "https"
        else { return }
        NSWorkspace.shared.open(targetURL)
    }
}

extension LineBreakTerminalView: TerminalSurfaceBellDelegate {
    func terminalDidRingBell() {
        NSSound.beep()
    }
}

extension LineBreakTerminalView: TerminalSurfaceClipboardConfirmationDelegate {
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        request.respond(allow: request.kind == .paste)
    }
}

func focusTerminal(_ view: LocalProcessTerminalView?) {
    DispatchQueue.main.async {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

func focusRemainingTerminal() {
    DispatchQueue.main.async {
        guard let window = NSApp.keyWindow,
              let terminal = window.contentView?.firstTerminalDescendant()
        else { return }
        guard window.firstResponder === window else { return }
        window.makeFirstResponder(terminal)
    }
}

private extension NSView {
    func firstTerminalDescendant() -> LocalProcessTerminalView? {
        if let terminal = self as? LocalProcessTerminalView { return terminal }
        for subview in subviews {
            if let found = subview.firstTerminalDescendant() { return found }
        }
        return nil
    }
}

/// Embeds a Ghostty terminal running a direct agent or ordinary-terminal attach.
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let target: TerminalAttachTarget
    var serverVersion: String?
    let attachmentCapabilities: AgentAttachmentCapabilities?
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    var thinStrokes: Bool = true
    var fontWeight: Double = TerminalDefaults.defaultFontWeight
    var lineSpacing: Double = TerminalDefaults.defaultLineSpacing
    var dark: Bool = false
    var mouseReporting: Bool = TerminalDefaults.defaultMouseReporting
    var onAttachmentError: (String) -> Void = { _ in }
    var onAttachmentUploadingChanged: (Bool) -> Void = { _ in }
    var onExit: ((Int32?) -> Void)? = nil
    var onViewReady: ((LocalProcessTerminalView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LineBreakTerminalView()
        configurePasteHandling(view)
        view.processDelegate = context.coordinator
        context.coordinator.onExit = onExit
        configureAppearance(view)

        let service = HerdrService(device: device)
        view.attachmentService = service
        let command = service.attachCommand(target: target, serverVersion: serverVersion)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = "en_US.UTF-8"
        for (key, value) in command.environment {
            environment[key] = value
        }
        context.coordinator.authorizationID = command.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        view.startProcess(
            executable: command.executable,
            args: command.args,
            environment: environment
        )
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        configurePasteHandling(nsView)
        context.coordinator.onExit = onExit
        configureAppearance(nsView)
    }

    private func configurePasteHandling(_ view: LineBreakTerminalView) {
        view.attachmentCapabilities = attachmentCapabilities
        view.attachmentDeviceKind = device.kind
        view.onAttachmentError = onAttachmentError
        view.onAttachmentUploadingChanged = onAttachmentUploadingChanged
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.onExit = nil
        coordinator.discardAuthorization()
        nsView.terminate(signal: SIGHUP)
    }

    private func configureAppearance(_ view: LocalProcessTerminalView) {
        applyTerminalAppearance(
            view,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            mouseReporting: mouseReporting
        )
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        nonisolated(unsafe) var authorizationID: UUID?
        var onExit: ((Int32?) -> Void)?

        deinit {
            discardAuthorization()
        }

        func scheduleAuthorizationCleanup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.discardAuthorization()
            }
        }

        nonisolated func discardAuthorization() {
            guard let authorizationID else { return }
            try? SSHCredentialStore.removeAuthorization(authorizationID)
            self.authorizationID = nil
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: LocalProcessTerminalView, directory: String?) {}
        func processTerminated(source: LocalProcessTerminalView, exitCode: Int32?) {
            discardAuthorization()
            let callback = onExit
            onExit = nil
            DispatchQueue.main.async { callback?(exitCode) }
        }
    }
}

@MainActor
func applyTerminalAppearance(
    _ view: LocalProcessTerminalView,
    fontName: String, fontSize: Double, thinStrokes: Bool,
    fontWeight: Double, lineSpacing: Double, dark: Bool, mouseReporting: Bool
) {
    view.mouseReporting = mouseReporting
    view.appliedDarkAppearance = dark
    view.usesLightColors = !dark
    if !dark {
        view.resetLightColorAdapter()
    }

    let config = TerminalConfiguration { builder in
        if !fontName.isEmpty {
            builder.withFontFamily(fontName)
        }
        builder.withFontSize(Float(fontSize))
        builder.withFontThicken(!thinStrokes)
        builder.withWindowPaddingX(TerminalDefaults.defaultPaddingX)
        builder.withWindowPaddingY(TerminalDefaults.defaultPaddingY)
        if dark {
            builder.withBackground(TerminalDefaults.darkHexBackground)
            builder.withForeground(TerminalDefaults.darkHexForeground)
            for (idx, color) in TerminalDefaults.darkHexPalette.enumerated() {
                builder.withPalette(idx, color: color)
            }
        } else {
            builder.withBackground(TerminalDefaults.lightHexBackground)
            builder.withForeground(TerminalDefaults.lightHexForeground)
            for (idx, color) in TerminalDefaults.lightHexPalette.enumerated() {
                builder.withPalette(idx, color: color)
            }
        }
        if abs(lineSpacing - 1.0) > 0.01 {
            builder.withCustom("adjust-cell-height", "\(Int((lineSpacing - 1.0) * 100))%")
        }
    }
    view.terminalController.setTerminalConfiguration(config)
    view.terminalController.setColorScheme(dark ? .dark : .light)
}

@MainActor
enum ShellViewRegistry {
    private struct WeakView { weak var view: LocalProcessTerminalView? }
    private static var views: [UUID: WeakView] = [:]

    static func register(_ view: LocalProcessTerminalView, for id: UUID) {
        views[id] = WeakView(view: view)
    }

    static func unregister(_ id: UUID) {
        views[id] = nil
    }

    static func focus(_ id: UUID) {
        DispatchQueue.main.async {
            guard let view = views[id]?.view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

struct ShellTerminalView: NSViewRepresentable {
    var sessionID: UUID?
    var device: Device = .local
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    var thinStrokes: Bool = true
    var fontWeight: Double = TerminalDefaults.defaultFontWeight
    var lineSpacing: Double = TerminalDefaults.defaultLineSpacing
    var dark: Bool = false
    var mouseReporting: Bool = TerminalDefaults.defaultMouseReporting
    var onExit: ((Int32?) -> Void)? = nil
    var onViewReady: ((LocalProcessTerminalView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LineBreakTerminalView()
        view.processDelegate = context.coordinator
        context.coordinator.onExit = onExit
        context.coordinator.sessionID = sessionID
        applyTerminalAppearance(
            view,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            mouseReporting: mouseReporting
        )

        let command = HerdrService(device: device, autoStartLocalServer: false)
            .terminalCommand()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = "en_US.UTF-8"
        for (key, value) in command.environment {
            environment[key] = value
        }
        context.coordinator.authorizationID = command.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        view.startProcess(
            executable: command.executable,
            args: command.args,
            environment: environment
        )
        if let sessionID {
            ShellViewRegistry.register(view, for: sessionID)
        }
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        applyTerminalAppearance(
            nsView,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            mouseReporting: mouseReporting
        )
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.onExit = nil
        coordinator.discardAuthorization()
        if let sessionID = coordinator.sessionID {
            ShellViewRegistry.unregister(sessionID)
        }
        nsView.terminate(signal: SIGHUP)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: ((Int32?) -> Void)?
        var sessionID: UUID?
        nonisolated(unsafe) var authorizationID: UUID?

        deinit {
            discardAuthorization()
        }

        func scheduleAuthorizationCleanup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.discardAuthorization()
            }
        }

        nonisolated func discardAuthorization() {
            guard let authorizationID else { return }
            try? SSHCredentialStore.removeAuthorization(authorizationID)
            self.authorizationID = nil
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: LocalProcessTerminalView, directory: String?) {}
        func processTerminated(source: LocalProcessTerminalView, exitCode: Int32?) {
            discardAuthorization()
            let callback = onExit
            onExit = nil
            DispatchQueue.main.async { callback?(exitCode) }
        }
    }
}
