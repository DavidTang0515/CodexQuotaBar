# Requirements

## Product Goal

CodexQuotaBar is a lightweight, local-first macOS menu bar utility that answers three questions without opening Codex:

1. How much 7-day Codex quota is left?
2. How many local Codex tokens were used?
3. What would those priced tokens cost at current OpenAI standard API rates?

The API value is an estimate, not a ChatGPT/Codex bill or official subscription balance.

## Core Display

- Keep one compact 7-day quota indicator in the macOS menu bar.
- Left-click opens one compact native `Codex Meter` `NSPanel` anchored to the status item.
- The compact panel shows three equal cards: 7-day quota, Codex Token, and API-equivalent value.
- The quota card stays on the current 7-day window; the Token period is selected in its card and the API-equivalent value follows it.
- `View Details` expands the same panel vertically; `Collapse Details` returns it to compact size without resizing the cards.
- Detailed ranges are Today, 7 days, 30 days, Current month, and All.
- The restrained detail view adds a daily trend and top-model summary below the unchanged cards.
- Keep the optional floating ball; clicking it opens the same cockpit panel.
- Avoid dense grids, project analytics, tool analytics, themes, or hardware metrics.

## Data Sources And Calculation

- Read quota through the local Codex app-server `account/rateLimits/read` method.
- Select the 10,080-minute window when available; if Codex exposes only one window, use that single current window.
- Read active and archived Codex JSONL files under `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Read `~/.codex/state_5.sqlite` only for thread-to-model metadata when JSONL model context is missing.
- Parse only structural metadata and cumulative `token_count` values.
- Delta-normalize cumulative snapshots before aggregation.
- Cached input is a subset of input. Estimate cost as:

```text
(input - cached input) × input price
+ cached input × cached-input price
+ output × output price
```

- Reasoning output is a detail of output and is not added a second time.
- Unknown models remain in token totals but are excluded from USD estimates and labeled unpriced.
- Time ranges use the Mac's local calendar and timezone.

## Pricing

- Seed the app with a versioned OpenAI API price table.
- On app launch and manual refresh, update prices only from official `developers.openai.com` model Markdown pages.
- The five-minute automatic refresh must not access pricing pages.
- If the network or parser fails, retain and use the last successful local price table.
- If no cached price exists, use the bundled seed; never invent a price for an unknown model.

## Refresh And Failure States

- Refresh quota and local usage at launch.
- Refresh quota and local usage automatically every five minutes.
- Manual refresh also attempts an official price refresh.
- Unchanged session files must be skipped by the local index.
- Show clear states for live, cached, partial, unavailable, no-token, and unpriced data.
- Never display demo values when real data is unavailable.

## Local Data And Uninstall

- Treat all Codex source files as read-only.
- Never read browser cookies or `~/.codex/auth.json`.
- Never store prompts, responses, tool arguments, or raw JSONL copies.
- Store only preferences, quota history, normalized token deltas, file signatures, and price cache under `~/Library/Application Support/CodexQuotaBar`.
- `Clear Local Data` must move the complete app-owned support directory to the system Trash and leave `~/.codex` untouched.
- All usage statistics must be rebuildable from the original Codex files.
- Do not install a LaunchAgent, daemon, cloud service, telemetry, analytics, or auto-updater.
- Open at Login remains an explicit user-controlled ServiceManagement toggle.

## Deployment

- Remain a native Swift/AppKit menu bar app with bundled Python helpers and system SQLite.
- Use existing macOS tools only; no new package manager or runtime dependency.
- Local builds stay inside the worktree and do not write to `/Applications`.
- Release packaging may provide DMG, zip, install notes, and SHA-256 checksums after visual approval.
