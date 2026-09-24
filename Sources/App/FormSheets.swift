import HerdrKit
import SwiftUI

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
func renameSpaceSheet(model: AppModel, entry: AppModel.SpaceEntry) -> some View {
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
func renameAgentSheet(model: AppModel, entry: AppModel.AgentEntry) -> some View {
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
func renameTerminalSheet(model: AppModel, entry: AppModel.TerminalEntry) -> some View {
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
