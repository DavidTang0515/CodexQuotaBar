# Tooling Ledger

This file records tools, runtimes, packages, and system changes installed specifically for CodexQuotaBar.

## Current Status

No project-specific tools have been installed yet.

The first local build used existing system tools already present on this Mac:

- `swiftc`
- `clang`
- `codesign`
- `/usr/bin/python3`
- `hdiutil`
- `ditto`
- `shasum`

These were not installed for this project, so there is nothing project-specific to uninstall.

Runtime-created files:

- `~/Library/Application Support/CodexQuotaBar/preferences.json`

This file stores UI preferences only, such as floating ball visibility and position. It can be deleted during uninstall if a fully clean removal is desired.

## Install Log

| Date | Tool | Version | Install Command | Purpose | Uninstall Notes |
|---|---|---|---|---|---|
| 2026-06-29 | None | - | - | Project created with docs only | Nothing to uninstall |
| 2026-06-29 | Existing Xcode Command Line Tools | system-provided | already present | Build local Swift menu bar app | Not installed by this project |
| 2026-06-29 | Existing macOS packaging tools | system-provided | already present | Package DMG, zip, and SHA-256 checksums | Not installed by this project |

## Rule

Before installing any tool, package, runtime, app, helper, LaunchAgent, or dependency for this project, add it here with the exact install command and uninstall notes.
