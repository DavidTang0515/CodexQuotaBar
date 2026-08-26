# Roadmap

## Phase 1: Proof of Concept

- Confirm local Codex CLI or app bundle path.
- Build a helper that reads `account/rateLimits/read` from the local Codex app-server.
- Return normalized JSON with:
  - `fiveHourLeft`
  - `sevenDayLeft`
  - `fiveHourReset`
  - `sevenDayReset`
  - `updatedAt`
- Print the result from the command line for inspection.

## Phase 2: Minimal Menu Bar App

- Create a native macOS status bar app with Swift and AppKit.
- Render two compact rows:
  - `5h`
  - `7d`
- Draw 5 equal-height quota bars per row.
- Treat each bar as about 20% quota.
- Keep the bars close to the percentage text.
- Show percentage text at the right side.
- Add menu actions:
  - Refresh
  - Open ChatGPT
  - Quit

## Phase 3: Visual Polish

- Match the compact blue status block style.
- Tune spacing for macOS menu bar height.
- Use green, orange, and red states.
- Do not add a right-side Codex icon; the reference image captured the native Codex icon by accident.

## Not In First Version

- Auto-update.
- LaunchAgent.
- SSD temperature.
- CPU or RAM display.
- Persistent logs.
- Local history database.
- Complex theme system.
- Installer that writes into `/Applications`.

## Version 0.4

- Keep the compact two-row `5h` and `7d` menu-bar display.
- Add local Token summaries in the menu without adding a cockpit window.
- Support today, 7 days, 30 days, this month, and all-record periods.
- Show input, cached input, and output composition from explicit local Token metadata.
- Keep the last valid quota visible when a refresh fails or times out.
- Avoid unnecessary status-item redraws when values have not changed.
- Keep all app-owned history, Token index, and preferences local and removable through `Clear Local Data...`.
