# Requirements

## Product Goal

CodexQuotaBar is a lightweight macOS menu bar utility for checking Codex quota without opening Codex repeatedly.

The app should answer one question quickly:

```text
How much Codex quota do I have left?
```

## Core Display

- Show `5h` quota and `7d` quota in the macOS menu bar.
- Use a compact two-row layout:

```text
5h  [5 bars]  52%
7d  [5 bars]  42%
```

- Use 5 equal-height bars per row.
- Each bar represents about 20% quota.
- Keep bars close to the percentage text.
- Do not add a right-side Codex icon.
- Use simple status colors:
  - Green: greater than 60%
  - Orange: 20% to 60%
  - Red: less than 20%

## Interaction

- Open as a normal user app.
- Show status in the menu bar while running.
- Provide a small menu with:
  - Manual refresh
  - Last refresh time
  - Reset time if available
  - Recent quota usage trend
  - Local Token totals for today, 7 days, 30 days, this month, or all records
  - Local Token input, cached input, and output composition
  - Projected 5-hour quota duration
  - Show or hide the optional floating ball
  - Enable or disable Open at Login
  - Open ChatGPT
  - Clear Local Data
  - Quit
- Floating ball mode is optional and experimental.
- Floating ball mode should be shown by default.
- Floating ball visibility and position should be remembered.
- UI preferences and quota history may be persisted locally.

## Deployment

- Keep deployment lightweight.
- First public test version should ship as a DMG.
- The DMG should let users manually drag `CodexQuotaBar.app` into `/Applications`.
- The app and scripts should not automatically write into `/Applications`.
- The app should avoid LaunchAgent, daemon, background service, or auto-updater.
- Open at Login is allowed only as an explicit user-controlled toggle.
- Open at Login should use macOS ServiceManagement instead of a custom LaunchAgent plist.
- Prefer a local build/run workflow before packaging.
- GitHub Releases should include a DMG, a zip fallback, install notes, and SHA-256 checksums.

## Local File Safety

- Treat the app as read-only.
- Do not modify Codex files.
- Do not modify user project files.
- Do not scan unrelated folders.
- Do not delete files or directories.
- Do not use batch-delete commands such as `rm -rf`.
- Do not create logs, caches, or reports.
- UI preferences may be saved to `~/Library/Application Support/CodexQuotaBar/preferences.json`.
- UI preferences may include floating ball visibility, position, and the selected Token period.
- Quota history may be saved to `~/Library/Application Support/CodexQuotaBar/history.sqlite`.
- Quota history may include timestamps, remaining quota percentages, reset times, plan, and source only.
- A local Token index may be saved to `~/Library/Application Support/CodexQuotaBar/usage.sqlite`.
- The Token index may contain only timestamps, Token counts, model identifiers, and source-file scan metadata needed for incremental updates.
- Quota history should be pruned to the recent retention window.
- Users should be able to move local CodexQuotaBar data to Trash from the app menu.
- Do not read browser cookies.
- Do not read `~/.codex/auth.json`.
- Do not store prompts or responses.
- The Codex CLI may maintain its own runtime state under `~/.codex`; CodexQuotaBar must not inspect or modify that state directly.

## Data Source

- Prefer reading quota through the local Codex app-server.
- Support the CLI bundled with ChatGPT, a standalone Codex CLI, and the legacy Codex desktop app.
- Only request quota/rate-limit information.
- Do not inspect conversation contents.
- Local Token summaries may inspect only explicit Token-count, timestamp, and model metadata in `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Do not extract, display, or store prompts, responses, project paths, or other conversation content.
- Do not present quota-percentage trends as Token counts. Local Token summaries must be labeled as local and must aggregate only explicit Token-count metadata.

## Latency And Refresh

- Manual refresh should feel immediate.
- Target manual refresh response time: within 1 to 3 seconds when Codex local service is available.
- Automatic refresh should be conservative by default.
- Initial automatic refresh interval: 5 minutes.
- If the app cannot read live quota, show a clear unavailable state instead of guessing.
- Avoid aggressive polling that may disturb Codex usage windows or waste battery.

## Non-Goals

- No SSD temperature.
- No CPU or RAM display.
- No auto-update.
- No LaunchAgent.
- No custom LaunchAgent login item.
- No local database beyond the app-owned quota history and Token-index SQLite files.
- No telemetry.
- No analytics.
- No cloud sync.
- No installer package.
