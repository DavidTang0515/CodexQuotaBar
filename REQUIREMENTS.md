# Requirements

## Product Goal

CodexQuotaBar is a lightweight macOS menu bar utility for checking Codex quota without opening Codex repeatedly.

The first version should answer one question quickly:

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
  - Show or hide the optional floating ball
  - Open Codex
  - Quit
- Floating ball mode is optional and experimental.
- Floating ball mode should not be shown by default.
- Floating ball mode should not persist position in the first version.

## Deployment

- Keep deployment lightweight.
- First public test version should ship as a DMG.
- The DMG should let users manually drag `CodexQuotaBar.app` into `/Applications`.
- The app and scripts should not automatically write into `/Applications`.
- First version should avoid LaunchAgent, login item, daemon, background service, or auto-updater.
- Prefer a local build/run workflow before packaging.
- GitHub Releases should include a DMG, a zip fallback, install notes, and SHA-256 checksums.

## Local File Safety

- Treat the app as read-only.
- Do not modify Codex files.
- Do not modify user project files.
- Do not scan unrelated folders.
- Do not delete files or directories.
- Do not use batch-delete commands such as `rm -rf`.
- Do not create logs, histories, caches, or reports in the first version.
- Do not read browser cookies.
- Do not read `~/.codex/auth.json`.
- Do not store prompts or responses.

## Data Source

- Prefer reading quota through the local Codex app-server.
- Only request quota/rate-limit information.
- Do not inspect conversation contents.
- Do not inspect session file contents unless explicitly approved later.

## Latency And Refresh

- Manual refresh should feel immediate.
- Target manual refresh response time: within 1 to 3 seconds when Codex local service is available.
- Automatic refresh should be conservative by default.
- Initial automatic refresh interval: 5 minutes.
- If the app cannot read live quota, show a clear unavailable state instead of guessing.
- Avoid aggressive polling that may disturb Codex usage windows or waste battery.

## First Version Non-Goals

- No SSD temperature.
- No CPU or RAM display.
- No auto-update.
- No LaunchAgent.
- No login item.
- No local database.
- No telemetry.
- No analytics.
- No cloud sync.
- No installer package.
