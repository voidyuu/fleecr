### Changed
- Switch release packaging to local Xcode toolchain to ensure complete AppIcon and asset catalog compilation.
- Update release automation to local `make release` workflow and Homebrew tap integration.

### Changed
- The ⌘N shortcut now creates a new space (previously ⌘⇧N).
- The ⌘K search panel is now a native-style search bar that lives in the
  toolbar: results appear in a dropdown below the bar while typing, ranked the
  same way as before (needs input, unread, working, then the rest). ⌘K toggles
  the bar, ↑↓ navigate, ↩ opens, Esc or clicking the terminal dismisses, and
  the separate magnifying-glass toolbar button is gone since the bar is always
  visible.
- Naming now belongs to the backend: space and tab names shown in the sidebar
  are exactly the labels herdr reports, and every rename writes through
  herdr's own `workspace.rename` / `tab.rename` RPCs — the same ones the herdr
  TUI uses — so fleecr, the herdr TUI, and `herdr api snapshot` always agree.
  Renames made in the herdr TUI show up here automatically, and vice versa.
- The app no longer auto-renames spaces to follow the first terminal's
  directory. herdr names a space itself when it is created; only an explicit
  rename (here or in the TUI) changes the label afterwards.
- Rename Agent now edits the tab's stored name instead of the composed display
  title, so a rename no longer bakes the "2 · pi › …" index prefix or the
  terminal's OSC title into the backend label.

### Added
- Tab navigation shortcuts: ⌃⇥ (Ctrl+Tab) switches to the next tab, and ⌃⇧⇥ (Ctrl+Shift+Tab)
  returns to the previous tab. The cycling loops through both agent and terminal
  tabs together in the current space. Both shortcuts are customizable in
  Preferences → Shortcuts.
- A default ⌘W shortcut closes the currently selected terminal or agent pane
  (with the usual confirmation), instead of closing the window. It applies only
  while the main console window is focused — with the Settings window focused,
  ⌘W keeps its system meaning and closes that window.
- Terminals can be renamed from the sidebar context menu. The tab label is
  written to herdr and displayed over the pane's OSC title, so renames are
  always visible.