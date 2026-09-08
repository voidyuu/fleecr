import SwiftUI

struct ShortcutsSettingsView: View {
    @StateObject private var store = ShortcutStore.shared
    @State private var searchQuery = ""
    @State private var showResetAllConfirmation = false
    @State private var hoveredItemId: String?

    private var filteredItems: [ShortcutItem] {
        if searchQuery.isEmpty {
            return store.items
        }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return store.items.filter { item in
            let matchesName = item.name.lowercased().contains(q)
            let matchesDesc = item.description?.lowercased().contains(q) ?? false
            let currentShortcut = store.shortcut(for: item)?.displayString.lowercased() ?? ""
            let matchesShortcut = currentShortcut.contains(q)
            return matchesName || matchesDesc || matchesShortcut
        }
    }

    private var categoriesInResults: [ShortcutCategory] {
        ShortcutCategory.allCases.filter { cat in
            cat != .all && filteredItems.contains(where: { $0.category == cat })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Controls: Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField(String(localized: "shortcut.search.placeholder", defaultValue: "Search shortcuts…"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textGhost)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )

            // Main List View
            if filteredItems.isEmpty {
                emptyStateView
                    .frame(height: 330)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if searchQuery.isEmpty {
                            ForEach(categoriesInResults) { cat in
                                Section {
                                    let itemsInCat = filteredItems.filter { $0.category == cat }
                                    ForEach(itemsInCat) { item in
                                        itemRow(item)
                                    }
                                } header: {
                                    categoryHeader(cat)
                                }
                            }
                        } else {
                            ForEach(filteredItems) { item in
                                itemRow(item)
                            }
                        }
                    }
                }
                .frame(height: 330)
            }

            // Footer
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text(String(localized: "shortcut.footer.tip", defaultValue: "Click shortcut to record · Esc to cancel · ⌫ to clear"))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

                Spacer()

                Button(String(localized: "shortcut.resetAll", defaultValue: "Reset All…")) {
                    showResetAllConfirmation = true
                }
                .controlSize(.small)
                .disabled(store.bindings.isEmpty)
            }
        }
        .padding(20)
        .onDisappear {
            store.stopRecording()
        }
        .confirmationDialog(
            String(localized: "shortcut.resetAll.title", defaultValue: "Reset all shortcuts to their defaults?"),
            isPresented: $showResetAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "shortcut.resetAll.confirm", defaultValue: "Reset All to Defaults"), role: .destructive) {
                store.resetAll()
            }
            Button(String(localized: "Cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }

    private func categoryHeader(_ category: ShortcutCategory) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(category.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func itemRow(_ item: ShortcutItem) -> some View {
        let conflicts = store.conflicts(for: item)
        let isHovered = hoveredItemId == item.id

        return HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let desc = item.description {
                    Text(desc)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !conflicts.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                    Text(String(localized: "shortcut.conflict", defaultValue: "Conflict"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                }
                .help(String(format: String(localized: "shortcut.conflict.detail", defaultValue: "Conflicts with: %@"), conflicts.map(\.name).joined(separator: ", ")))
            }

            if !store.isDefault(for: item) {
                Button(action: {
                    store.resetToDefault(for: item)
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "shortcut.resetToDefault", defaultValue: "Reset to default"))
            }

            ShortcutRecorderView(item: item, store: store)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Theme.itemWashSelected : Color.clear)
        )
        .onHover { hovered in
            if hovered {
                hoveredItemId = item.id
            } else if hoveredItemId == item.id {
                hoveredItemId = nil
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textGhost)
            Text(String(localized: "shortcut.empty.title", defaultValue: "No Shortcuts Found"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(String(localized: "shortcut.empty.desc", defaultValue: "Try a different search query"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textGhost)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
