import Foundation
import HerdrKit
import SwiftUI

extension AppModel {
    // MARK: - Store Reconciliation

    func reconcileDevicesFromStore() {
        let loaded = store.load()
        guard loaded != devices else { return }

        let oldDevices = devices
        let oldIDs = Set(oldDevices.map(\.id))
        let newIDs = Set(loaded.map(\.id))

        // 1. Clean up removed devices
        for removedID in oldIDs.subtracting(newIDs) {
            stopSession(removedID)
            removeSSHPassword(for: removedID)
        }

        // 2. Prepare reconciled devices preserving cached osID
        var reconciled: [Device] = []
        for var newDevice in loaded {
            if let oldDevice = oldDevices.first(where: { $0.id == newDevice.id }),
               oldDevice.sshTarget == newDevice.sshTarget {
                newDevice.osID = oldDevice.osID
            }
            reconciled.append(newDevice)
        }

        // 3. Connect, reconnect, or disconnect modified/added devices
        for newDevice in reconciled {
            if let oldDevice = oldDevices.first(where: { $0.id == newDevice.id }) {
                let targetChanged = oldDevice.sshTarget != newDevice.sshTarget
                let sessionChanged = oldDevice.session != newDevice.session
                let enabledChanged = oldDevice.isEnabled != newDevice.isEnabled

                if targetChanged || sessionChanged {
                    if targetChanged { removeSSHPassword(for: newDevice.id) }
                    stopSession(newDevice.id)
                    if newDevice.isEnabled {
                        startSession(newDevice)
                        probeOSIfNeeded(newDevice)
                    } else {
                        sessions[newDevice.id] = DeviceSessionState(connection: .idle)
                    }
                } else if enabledChanged {
                    if newDevice.isEnabled {
                        startSession(newDevice)
                        probeOSIfNeeded(newDevice)
                    } else {
                        stopSession(newDevice.id)
                        sessions[newDevice.id] = DeviceSessionState(connection: .idle)
                    }
                }
            } else {
                // Brand new device
                if newDevice.isEnabled {
                    startSession(newDevice)
                    probeOSIfNeeded(newDevice)
                } else {
                    sessions[newDevice.id] = DeviceSessionState(connection: .idle)
                }
            }
        }

        devices = reconciled
    }

    func addDevice(name: String, sshTarget: String, session: String = "default") async throws {
        let trimmedSession = session.trimmingCharacters(in: .whitespaces)
        let resolvedSession = trimmedSession.isEmpty ? "default" : trimmedSession
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTarget = sshTarget.trimmingCharacters(in: .whitespaces)
        let resolvedName = trimmedName.isEmpty ? trimmedTarget : trimmedName

        try await HerdrMachineCLI.add(
            target: trimmedTarget,
            label: resolvedName,
            session: resolvedSession
        )

        reconcileDevicesFromStore()
    }

    func saveSSHPassword(_ password: String, for request: SSHAuthenticationRequest) {
        guard !password.isEmpty,
              let device = device(request.deviceID),
              device.sshTarget == request.target
        else { return }
        do {
            try SSHCredentialStore.setPassword(password, for: device.id)
            sshAuthenticationRequest = nil
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Leaves the device disconnected but recoverable; the reconnect loop stopped at the prompt.
    func cancelSSHAuthentication(for request: SSHAuthenticationRequest) {
        sshAuthenticationRequest = nil
        sessions[request.deviceID]?.connection =
            .failed(String(localized: "Authentication cancelled — choose Reconnect to try again"))
    }

    var hasReconnectableDevice: Bool {
        devicesInScope.contains { $0.isEnabled && isFailed($0.id) }
    }

    func reconnectFailedDevices() {
        for device in devicesInScope where device.isEnabled && isFailed(device.id) {
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        }
    }

    private func isFailed(_ deviceID: UUID) -> Bool {
        if case .failed = session(deviceID).connection { return true }
        return false
    }

    /// Renames a device and/or updates its SSH target, session, or enabled state via official herdr CLI.
    func updateDevice(
        _ id: UUID,
        name: String,
        sshTarget: String,
        session: String = "default",
        isEnabled: Bool = true
    ) async throws {
        guard let current = device(id), !current.isLocal else { return }
        let targetChanged = current.sshTarget != sshTarget
        let sessionChanged = current.session != session
        let nameChanged = current.name != name
        let enabledChanged = current.isEnabled != isEnabled

        let profileID = id.profileIDString

        if targetChanged || sessionChanged {
            try await HerdrMachineCLI.remove(profileID: profileID)
            try await HerdrMachineCLI.add(
                target: sshTarget,
                label: name,
                session: session.isEmpty ? "default" : session
            )
            if !isEnabled {
                if let updated = store.load().first(where: { $0.sshTarget == sshTarget }) {
                    try? await HerdrMachineCLI.disable(profileID: updated.id.profileIDString)
                }
            }
        } else {
            if nameChanged {
                try await HerdrMachineCLI.rename(profileID: profileID, label: name)
            }
            if enabledChanged {
                if isEnabled {
                    try await HerdrMachineCLI.enable(profileID: profileID)
                } else {
                    try await HerdrMachineCLI.disable(profileID: profileID)
                }
            }
        }

        reconcileDevicesFromStore()
    }

    func setDeviceEnabled(_ device: Device, enabled: Bool) {
        guard !device.isLocal else { return }
        Task {
            if enabled {
                try? await HerdrMachineCLI.enable(profileID: device.id.profileIDString)
            } else {
                try? await HerdrMachineCLI.disable(profileID: device.id.profileIDString)
            }
            await MainActor.run {
                self.reconcileDevicesFromStore()
            }
        }
    }

    func toggleDeviceEnabled(_ device: Device) {
        setDeviceEnabled(device, enabled: !device.isEnabled)
    }

    func removeDevice(_ device: Device) {
        guard !device.isLocal else { return }
        removeSSHPassword(for: device.id)
        if sshAuthenticationRequest?.deviceID == device.id { sshAuthenticationRequest = nil }
        stopSession(device.id)
        devices.removeAll { $0.id == device.id }
        if selectedSpace?.deviceID == device.id {
            selectedSpace = visibleSpaces.first(where: { $0.device.id != device.id })?.ref
        }
        if selectedPane?.deviceID == device.id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
        Task {
            try? await HerdrMachineCLI.remove(profileID: device.id.profileIDString)
            await MainActor.run {
                self.reconcileDevicesFromStore()
            }
        }
    }

}
