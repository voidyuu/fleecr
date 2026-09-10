---
name: fleecr-release
description: >-
  Standard workflow and procedures for releasing a new version of fleecr.
  Use this skill whenever the user asks to release, publish, or bump fleecr
  (e.g., "发版", "发布新版本", "release new version", "bump version").
---

# Fleecr Release Skill

This skill defines the canonical procedure for releasing a new version of **fleecr**.

> **IMPORTANT**:
> Always build **locally** using the developer's macOS environment and local Xcode toolchain.
> Do **NOT** use cloud GitHub Actions to build. Cloud runners lack Xcode 27 support for compiling `.icon` assets, which would result in missing AppIcon and Assets.car.

---

## Pre-release Checklist

Before running the release process, verify the following:

1. **Working Tree**:
   Run `git status`. Ensure there are no unintended uncommitted changes.
2. **Changelog Section**:
   Check `CHANGELOG.md`. The target version (e.g. `0.7.0`) must have a corresponding header:
   ```markdown
   ## [0.7.0] - YYYY-MM-DD

   ### Changed / Added / Fixed
   - ...
   ```
   If there are notes under `## [Unreleased]`, promote them into the new version section.
3. **GitHub CLI Authentication**:
   Ensure `gh auth status` is logged in as `voidyuu`.
4. **Local Tap Directory**:
   Verify that `~/Developer/homebrew-tap` exists and has a clean git status.

---

## Release Procedure

Release execution is fully automated via the project's [Makefile](file:///Users/cassiel/Developer/herdrm/Makefile) and [scripts/release.sh](file:///Users/cassiel/Developer/herdrm/scripts/release.sh).

### Step 1: Run the Release Command

Run from the repository root:

```bash
make release VERSION=<version>
```
*Example:*
```bash
make release VERSION=0.7.0
```

### What the Release Automation Does:

1. **Validates Changelog**: Verifies that `CHANGELOG.md` contains `## [<version>]` and extracts notes into `notes.md`.
2. **Generates Project**: Runs `xcodegen generate` to ensure `fleecr.xcodeproj` matches `project.yml`.
3. **Compiles Release Binary**:
   - Compiles universal binary (`arm64` and `x86_64`) via `xcodebuild -configuration Release`.
   - Uses local Xcode 27 to properly generate `AppIcon.icns`, `Assets.car`, and all resources.
   - Code-signs locally (`-s -`).
4. **Packages Archive**: Creates `fleecr-<version>.zip` using `ditto` and computes its SHA256.
5. **Git Operations**:
   - Commits any modified files (`git commit -m "chore: release v<version>"`).
   - Creates and pushes git tag `v<version>`.
   - Pushes `main` to `origin`.
6. **GitHub Release**:
   - Creates or updates the release on `voidyuu/fleecr`.
   - Attaches `fleecr-<version>.zip` and populates the release notes from `CHANGELOG.md`.
7. **Homebrew Tap Bump**:
   - Pulls `~/Developer/homebrew-tap`.
   - Updates `version` and `sha256` in `Casks/fleecr.rb`.
   - Commits (`chore(fleecr): bump to <version>`) and pushes to `voidyuu/homebrew-tap`.

---

## Post-release Verification

After `make release` finishes:

1. **Verify GitHub Release**:
   ```bash
   gh release view "v<version>" -R voidyuu/fleecr
   ```
2. **Update & Verify Local Homebrew Tap**:
   ```bash
   cd /opt/homebrew/Library/Taps/voidyuu/homebrew-tap && git pull
   brew info --cask voidyuu/tap/fleecr
   ```
3. **Verify Installation**:
   ```bash
   brew reinstall voidyuu/tap/fleecr
   ```
   Check that `/Applications/Fleecr.app` launches and displays the correct icon and version in `About Fleecr`.

---

## Common Issues & Recovery

* **Missing CHANGELOG.md header**:
  If the script halts with `Error: CHANGELOG.md has no section for [x.y.z]`, edit `CHANGELOG.md` to add `## [x.y.z] - YYYY-MM-DD` and re-run.
* **Tap Directory Missing**:
  If `~/Developer/homebrew-tap` is missing, clone it via:
  ```bash
  git clone https://github.com/voidyuu/homebrew-tap.git ~/Developer/homebrew-tap
  ```
* **Git Remote Conflict**:
  If push fails due to remote divergence, run `git pull --rebase origin main` before retrying.
