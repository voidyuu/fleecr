import HerdrKit
import SwiftUI

struct DevicesSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showAddDevice = false
    @State private var deviceToEdit: Device?
    @State private var deviceToDelete: Device?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Configured Devices", defaultValue: "Configured Devices"))
                    .font(.system(size: 13, weight: .semibold))
                Text(String(localized: "All enabled machines stay connected in parallel. Fleecr displays sessions and spaces across all devices simultaneously.", defaultValue: "All enabled machines stay connected in parallel. Fleecr displays sessions and spaces across all devices simultaneously."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                if model.devices.count > 5 {
                    ScrollView {
                        deviceListContent
                    }
                    .scrollContentBackground(.hidden)
                    .frame(height: 240)
                } else {
                    deviceListContent
                }

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)

                bottomToolbar
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.sidebarBorder, lineWidth: 1)
            )
        }
        .padding(20)
        .frame(width: 480)
        .sheet(isPresented: $showAddDevice) {
            AddDeviceSheet(model: model)
        }
        .sheet(item: $deviceToEdit) { device in
            EditDeviceSheet(model: model, device: device)
        }
        .alert(item: $deviceToDelete) { device in
            let target = device.sshTarget ?? ""
            return Alert(
                title: Text(String(localized: "Remove \(device.name)?")),
                message: Text(String(localized: "Are you sure you want to remove \(device.name) (\(target))?")),
                primaryButton: .destructive(Text(String(localized: "Remove"))) {
                    model.removeDevice(device)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var deviceListContent: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                }
                deviceRow(device)
            }
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        let sessionState = model.session(device.id)
        let connection = sessionState.connection

        return HStack(spacing: 12) {
            DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 16)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .opacity(device.isEnabled ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .opacity(device.isEnabled ? 1 : 0.6)

                    Circle()
                        .fill(connectionDotColor(device: device, connection: connection))
                        .frame(width: 6, height: 6)

                    Text(statusText(device: device, connection: connection))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Text(device.localizedSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !device.isLocal {
                Toggle("", isOn: Binding(
                    get: { device.isEnabled },
                    set: { _ in model.toggleDeviceEnabled(device) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(device.isEnabled ? String(localized: "Disable Machine") : String(localized: "Enable Machine"))

                Button {
                    deviceToEdit = device
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Edit \(device.name)…"))

                Button {
                    deviceToDelete = device
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.danger.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Remove \(device.name)"))
            } else {
                Text(String(localized: "Local", defaultValue: "Local"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.itemWash, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var bottomToolbar: some View {
        HStack(spacing: 12) {
            Button {
                showAddDevice = true
            } label: {
                Label(String(localized: "Add Device…", defaultValue: "Add Device…"), systemImage: "plus")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)

            Spacer()

            if model.hasReconnectableDevice {
                Button {
                    model.reconnectFailedDevices()
                } label: {
                    Label(String(localized: "Reconnect Failed", defaultValue: "Reconnect Failed"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.warning)
            }

            Text(String(localized: "\(model.devices.count) devices · \(connectedCount) connected"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.itemWash)
    }

    private var connectedCount: Int {
        model.devices.filter {
            if case .connected = model.session($0.id).connection { return true }
            return false
        }.count
    }

    private func connectionDotColor(device: Device, connection: ConnectionState) -> Color {
        if !device.isEnabled { return Theme.textGhost }
        switch connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }

    private func statusText(device: Device, connection: ConnectionState) -> String {
        if !device.isEnabled { return String(localized: "Disabled", defaultValue: "Disabled") }
        switch connection {
        case .connected(let version):
            let conn = String(localized: "Connected", defaultValue: "Connected")
            return version.isEmpty ? conn : "\(conn) · v\(version)"
        case .connecting:
            return String(localized: "Connecting…")
        case .failed(let reason):
            return reason
        case .idle:
            return String(localized: "Idle", defaultValue: "Idle")
        }
    }
}
