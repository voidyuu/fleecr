import Foundation

// MARK: - UUID <-> Herdr 0.9 ProfileId

extension UUID {
    /// 32-character lowercase hex string without dashes, matching Herdr 0.9 `ProfileId`.
    public var profileIDString: String {
        uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// Derives a standard UUID from a 32-character lowercase hex Herdr `ProfileId`.
    public init?(profileID: String) {
        let cleaned = profileID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count == 32,
              cleaned.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        let index8 = cleaned.index(cleaned.startIndex, offsetBy: 8)
        let index12 = cleaned.index(index8, offsetBy: 4)
        let index16 = cleaned.index(index12, offsetBy: 4)
        let index20 = cleaned.index(index16, offsetBy: 4)

        let formatted = "\(cleaned[..<index8])-\(cleaned[index8..<index12])-\(cleaned[index12..<index16])-\(cleaned[index16..<index20])-\(cleaned[index20...])"
        self.init(uuidString: formatted)
    }
}

// MARK: - Herdr 0.9 Official Endpoint Models

/// An SSH endpoint saved in Herdr 0.9's `endpoints.json`.
/// Note: Herdr uses `#[serde(deny_unknown_fields)]`, so field names and types must match strictly.
public struct SavedSshEndpoint: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var target: String
    public var session: String
    public var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case target
        case session
        case enabled
    }

    public init(
        id: String,
        label: String,
        target: String,
        session: String = "default",
        enabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.target = target
        self.session = session.isEmpty ? "default" : session
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.label = try container.decode(String.self, forKey: .label)
        self.target = try container.decode(String.self, forKey: .target)
        self.session = try container.decodeIfPresent(String.self, forKey: .session) ?? "default"
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Official Herdr 0.9 endpoint catalog (`~/.local/state/herdr/client/endpoints.json`).
public struct EndpointCatalog: Codable, Sendable, Equatable {
    public var version: Int
    public var selectedProfile: String?
    public var ssh: [SavedSshEndpoint]

    enum CodingKeys: String, CodingKey {
        case version
        case selectedProfile = "selected_profile"
        case ssh
    }

    public init(version: Int = 1, selectedProfile: String? = nil, ssh: [SavedSshEndpoint] = []) {
        self.version = version
        self.selectedProfile = selectedProfile
        self.ssh = ssh
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.selectedProfile = try container.decodeIfPresent(String.self, forKey: .selectedProfile)
        self.ssh = try container.decodeIfPresent([SavedSshEndpoint].self, forKey: .ssh) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        if let selectedProfile {
            try container.encode(selectedProfile, forKey: .selectedProfile)
        }
        try container.encode(ssh, forKey: .ssh)
    }
}

/// Official Herdr 0.9 selection file (`~/.local/state/herdr/client/endpoint-selection.json`).
public struct EndpointSelection: Codable, Sendable, Equatable {
    public var version: Int
    public var selectedProfile: String?

    enum CodingKeys: String, CodingKey {
        case version
        case selectedProfile = "selected_profile"
    }

    public init(version: Int = 1, selectedProfile: String? = nil) {
        self.version = version
        self.selectedProfile = selectedProfile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.selectedProfile = try container.decodeIfPresent(String.self, forKey: .selectedProfile)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        if let selectedProfile {
            try container.encode(selectedProfile, forKey: .selectedProfile)
        } else {
            try container.encodeNil(forKey: .selectedProfile)
        }
    }
}

// MARK: - Device Model

/// A machine running herdr. `local` talks straight to the Unix socket;
/// `ssh` reaches the remote socket through an OpenSSH stream-local forward.
public struct Device: Codable, Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: Codable, Sendable, Equatable, Hashable {
        case local
        case ssh(target: String)   // e.g. "vincent@10.10.10.87" or "vincent@mac-studio.tail"
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Socket path override; nil means the default session socket (~/.config/herdr/herdr.sock).
    public var socketPath: String?
    /// Sniffed operating system id ("macos", "ubuntu", "debian", …); cached after first probe.
    public var osID: String?
    /// Remote herdr session name; defaults to "default".
    public var session: String
    /// Whether this machine is enabled in Herdr.
    public var isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case socketPath
        case osID
        case session
        case isEnabled
    }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        socketPath: String? = nil,
        osID: String? = nil,
        session: String = "default",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.socketPath = socketPath
        self.osID = osID
        self.session = session.isEmpty ? "default" : session
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.socketPath = try container.decodeIfPresent(String.self, forKey: .socketPath)
        self.osID = try container.decodeIfPresent(String.self, forKey: .osID)
        self.session = try container.decodeIfPresent(String.self, forKey: .session) ?? "default"
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public init(endpoint: SavedSshEndpoint) {
        let uuid = UUID(profileID: endpoint.id) ?? UUID()
        self.init(
            id: uuid,
            name: endpoint.label,
            kind: .ssh(target: endpoint.target),
            session: endpoint.session,
            isEnabled: endpoint.enabled
        )
    }

    public func toSavedSshEndpoint() -> SavedSshEndpoint? {
        guard case .ssh(let target) = kind else { return nil }
        return SavedSshEndpoint(
            id: id.profileIDString,
            label: name,
            target: target,
            session: session.isEmpty ? "default" : session,
            enabled: isEnabled
        )
    }

    public static let local = Device(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Local",
        kind: .local,
        osID: "macos"
    )

    public var isLocal: Bool {
        if case .local = kind { return true }
        return false
    }

    public var sshTarget: String? {
        if case .ssh(let target) = kind { return target }
        return nil
    }

    public var subtitle: String {
        switch kind {
        case .local: return "This Mac · herdr.sock"
        case .ssh(let target):
            if session != "default" && !session.isEmpty {
                return "\(target) (\(session)) · SSH"
            }
            return "\(target) · SSH"
        }
    }
}

// MARK: - DeviceStore (Herdr 0.9 Official Catalog & Selection)

/// Persists the device list using the official Herdr 0.9 endpoints catalog
/// (`~/.local/state/herdr/client/endpoints.json`) and selection file
/// (`~/.local/state/herdr/client/endpoint-selection.json`).
public final class DeviceStore: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("dev.bybee.fleecr.DeviceStoreDidChange")

    public let directoryURL: URL
    public let endpointsURL: URL
    public let selectionURL: URL
    public let legacyFileURL: URL

    private let queue = DispatchQueue(label: "dev.bybee.fleecr.devices")
    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceTimer: DispatchSourceTimer?
    private var isSavingInternally = false

    public static var defaultDirectory: URL {
        if let xdgState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"],
           !xdgState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: xdgState, isDirectory: true)
                .appendingPathComponent("herdr/client", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/herdr/client", isDirectory: true)
    }

    public static var defaultLegacyDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
    }

    public init(directory: URL? = nil, legacyDirectory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directoryURL = base
        self.endpointsURL = base.appendingPathComponent("endpoints.json")
        self.selectionURL = base.appendingPathComponent("endpoint-selection.json")

        let leg = legacyDirectory ?? Self.defaultLegacyDirectory
        self.legacyFileURL = leg.appendingPathComponent("devices.json")
    }

    deinit {
        stopMonitoringInternal()
    }

    public func load() -> [Device] {
        queue.sync {
            // 1. Primary source of truth: official Herdr 0.9 endpoints.json
            if let data = try? Data(contentsOf: endpointsURL),
               let catalog = try? JSONDecoder().decode(EndpointCatalog.self, from: data) {
                var list = catalog.ssh.map { Device(endpoint: $0) }
                list.insert(.local, at: 0)
                return list
            }

            // 2. Migration fallback: legacy HerdrM devices.json
            if let legacyData = try? Data(contentsOf: legacyFileURL),
               let legacyDevices = try? JSONDecoder().decode([Device].self, from: legacyData),
               !legacyDevices.isEmpty {
                let nonLocal = legacyDevices.filter { !$0.isLocal }
                if !nonLocal.isEmpty {
                    // Migrate legacy devices to official Herdr endpoints.json
                    let endpoints = nonLocal.compactMap { $0.toSavedSshEndpoint() }
                    let catalog = EndpointCatalog(version: 1, ssh: endpoints)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    if let data = try? encoder.encode(catalog) {
                        try? data.write(to: endpointsURL, options: .atomic)
                    }
                    var list = endpoints.map { Device(endpoint: $0) }
                    list.insert(.local, at: 0)
                    return list
                }
            }

            // 3. Fallback to Local device only
            return [.local]
        }
    }

    public func save(_ devices: [Device]) {
        queue.sync {
            isSavingInternally = true
            defer {
                queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                    self?.isSavingInternally = false
                }
            }

            let sshEndpoints = devices.compactMap { $0.toSavedSshEndpoint() }

            // Preserve existing selected_profile in catalog if present
            var selectedProfile: String? = nil
            if let data = try? Data(contentsOf: endpointsURL),
               let catalog = try? JSONDecoder().decode(EndpointCatalog.self, from: data) {
                selectedProfile = catalog.selectedProfile
            }

            let catalog = EndpointCatalog(
                version: 1,
                selectedProfile: selectedProfile,
                ssh: sshEndpoints
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(catalog) {
                try? data.write(to: endpointsURL, options: .atomic)
            }
        }
    }

    public func loadSelectedProfile() -> UUID? {
        queue.sync {
            if let data = try? Data(contentsOf: selectionURL),
               let selection = try? JSONDecoder().decode(EndpointSelection.self, from: data),
               let profile = selection.selectedProfile,
               let uuid = UUID(profileID: profile) {
                return uuid
            }
            if let data = try? Data(contentsOf: endpointsURL),
               let catalog = try? JSONDecoder().decode(EndpointCatalog.self, from: data),
               let profile = catalog.selectedProfile,
               let uuid = UUID(profileID: profile) {
                return uuid
            }
            return nil
        }
    }

    public func saveSelectedProfile(_ id: UUID?) {
        queue.sync {
            isSavingInternally = true
            defer {
                queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                    self?.isSavingInternally = false
                }
            }

            let profileID: String?
            if let id, id != Device.local.id {
                profileID = id.profileIDString
            } else {
                profileID = nil
            }

            let selection = EndpointSelection(version: 1, selectedProfile: profileID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(selection) {
                try? data.write(to: selectionURL, options: .atomic)
            }
        }
    }

    // MARK: - Live File Monitoring

    public func startMonitoring(onChange: @escaping @Sendable () -> Void) {
        queue.async {
            self.stopMonitoringInternal()

            let fd = open(self.directoryURL.path, O_EVTONLY)
            guard fd >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib],
                queue: self.queue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if self.isSavingInternally { return }
                self.debounceTimer?.cancel()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + .milliseconds(150))
                timer.setEventHandler { [weak self] in
                    guard let self, !self.isSavingInternally else { return }
                    onChange()
                }
                self.debounceTimer = timer
                timer.resume()
            }
            source.setCancelHandler {
                close(fd)
            }
            self.directorySource = source
            source.resume()
        }
    }

    public func stopMonitoring() {
        queue.async {
            self.stopMonitoringInternal()
        }
    }

    private func stopMonitoringInternal() {
        debounceTimer?.cancel()
        debounceTimer = nil
        directorySource?.cancel()
        directorySource = nil
    }
}

// MARK: - Official Herdr Machine CLI

/// Invokes official `herdr machine` commands so all mutations go strictly through the official CLI.
public enum HerdrMachineCLI {
    public static func resolveBinary() -> String? {
        if let path = (ShellEnvironment.cached ?? .empty).findExecutable("herdr") {
            return path
        }
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path,
            "/usr/local/bin/herdr",
            "/opt/homebrew/bin/herdr",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin/herdr").path,
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func runCommand(
        args: [String],
        timeout: TimeInterval = 60
    ) async throws -> String {
        guard let binary = resolveBinary() else {
            throw HerdrError.tunnelFailed(
                "herdr CLI not found. Please ensure herdr is installed in ~/.local/bin or in your PATH."
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = args
                var env = (ShellEnvironment.cached ?? .empty).launchEnvironment(binary: nil)
                env.merge(ProcessInfo.processInfo.environment) { current, _ in current }
                proc.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                proc.standardOutput = stdoutPipe
                proc.standardError = stderrPipe

                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: HerdrError.tunnelFailed("Failed to spawn herdr: \(error.localizedDescription)"))
                    return
                }

                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if proc.isRunning { proc.terminate() }
                }

                proc.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    let message = !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        : (!stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                            : "herdr machine command exited with status \(proc.terminationStatus)")
                    continuation.resume(throwing: HerdrError.tunnelFailed(message))
                }
            }
        }
    }

    /// Prepares the remote Herdr server and saves an SSH machine using `herdr machine add`.
    public static func add(
        target: String,
        label: String,
        session: String = "default"
    ) async throws {
        var args = ["machine", "add", target, "--label", label]
        if session != "default" && !session.isEmpty {
            args += ["--remote-session", session]
        }
        _ = try await runCommand(args: args)
    }

    /// Removes a saved SSH machine using `herdr machine remove <profile-id>`.
    public static func remove(profileID: String) async throws {
        _ = try await runCommand(args: ["machine", "remove", profileID])
    }

    /// Renames a saved SSH machine using `herdr machine rename <profile-id> --label <label>`.
    public static func rename(profileID: String, label: String) async throws {
        _ = try await runCommand(args: ["machine", "rename", profileID, "--label", label])
    }

    /// Enables a saved SSH machine using `herdr machine enable <profile-id>`.
    public static func enable(profileID: String) async throws {
        _ = try await runCommand(args: ["machine", "enable", profileID])
    }

    /// Disables a saved SSH machine using `herdr machine disable <profile-id>`.
    public static func disable(profileID: String) async throws {
        _ = try await runCommand(args: ["machine", "disable", profileID])
    }
}


