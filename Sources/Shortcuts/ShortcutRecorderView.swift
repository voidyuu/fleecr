import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    let item: ShortcutItem
    @ObservedObject var store: ShortcutStore
    @State private var isHovered = false

    private var isRecording: Bool {
        store.recordingItemID == item.id
    }

    private var shortcut: KeyCombination? {
        store.shortcut(for: item)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if isRecording {
                    store.stopRecording()
                } else {
                    store.startRecording(for: item)
                }
            }) {
                HStack(spacing: 5) {
                    if isRecording {
                        recordingContent
                    } else if let shortcut = shortcut {
                        badgeContent(shortcut: shortcut)
                    } else {
                        unassignedContent
                    }
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 72)
                .frame(height: 24)
                .background(badgeBackground)
                .overlay(badgeBorder)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(isRecording ? String(localized: "shortcut.help.recording", defaultValue: "Press desired shortcut, Esc to cancel") : String(localized: "shortcut.help.record", defaultValue: "Click to record shortcut"))

            // Clear button if shortcut is assigned and not recording
            if !isRecording && shortcut != nil {
                Button(action: {
                    store.setShortcut(nil, for: item)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isHovered ? Theme.textTertiary : Theme.textGhost.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(String(localized: "shortcut.help.clear", defaultValue: "Remove shortcut"))
                .opacity(isHovered ? 1.0 : 0.0)
            }
        }
        .frame(height: 24)
        .animation(.easeInOut(duration: 0.15), value: isRecording)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    @ViewBuilder
    private var recordingContent: some View {
        if let err = store.validationError {
            Text(err)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.danger)
        } else if !store.liveModifiers.isEmpty {
            Text(KeyCombination.modifierSymbols(for: store.liveModifiers) + "…")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.working)
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(Theme.working)
                    .frame(width: 5, height: 5)
                Text(String(localized: "shortcut.state.recording", defaultValue: "Record…"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.working)
            }
        }
    }

    @ViewBuilder
    private func badgeContent(shortcut: KeyCombination) -> some View {
        Text(shortcut.displayString)
            .font(.system(size: 11.5, weight: .medium, design: .default))
            .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private var unassignedContent: some View {
        Text(String(localized: "shortcut.unassigned", defaultValue: "Record"))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textGhost)
    }

    @ViewBuilder
    private var badgeBackground: some View {
        if isRecording {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.working.opacity(0.12))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.itemWashSelected)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.itemWash)
        }
    }

    @ViewBuilder
    private var badgeBorder: some View {
        if isRecording {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.working, lineWidth: 1.5)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }
}
