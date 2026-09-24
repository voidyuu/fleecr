# Changelog

All notable changes to fleecr are documented in this file. The format is based
on [Keep a Changelog](https://keepachangelog.com); versions follow semver.
Release automation extracts the matching section for GitHub release notes —
a release without a section here fails CI.

## [Unreleased]

## [1.0.2] - 2026-09-24

### Added
- Persist the sidebar width.

### Changed
- Refactor app model, split view, and form sheet organization.

### Fixed
- Preserve Ghostty attach view identity.

## [1.0.1] - 2026-09-24

### Added
- Added a keyboard shortcut to rename tabs.
- Moved sidebar controls into the title bar.

### Fixed
- Animated the title bar controls when toggling the sidebar.
- Restored terminal focus after search and attach.
- Hardened local PTY startup and cleanup.
- Matched the terminal theme to the app appearance.

## [1.0.0] - 2026-09-10

### Added
- Initial release of Fleecr.
- Native macOS client for herdr, bringing AI coding agents and live terminals together.
- High-performance terminal emulation powered by libghostty with native PTY attach and custom themes.
- First-class support for Claude Code, Codex, Cursor, Gemini, Grok, OpenCode, pi, Kimi, and custom CLI agents.
- Multi-device and remote host management over SSH with auto-reconnect.
- Keyboard-first navigation: global ⌘K quick search, split panes (⌘D / ⇧⌘D), and tab cycling (⌃⇥ / ⌃⇧⇥).
