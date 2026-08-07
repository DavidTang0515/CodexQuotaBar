# Roadmap

## v0.4.0-temp — Real-data cockpit

- Index active and archived local Codex token metadata.
- Delta-normalize cumulative token snapshots.
- Estimate API value with official model prices and preserve unpriced tokens.
- Add one compact native `NSPanel` that expands vertically into a restrained detail view and returns in place.
- Support Today, 7 days, 30 days, Current month, and All.
- Keep the single 7-day menu bar indicator and optional floating ball.

## v0.4.1-temp — Reliability pass

- Validate changed, truncated, archived, and removed session files.
- Improve partial-data diagnostics and price-source visibility.
- Benchmark first scan and incremental refresh on large histories.
- Complete local-data cleanup, packaging, and uninstall verification.

## v0.5.0 — Mainline decision

- Collect visual and data feedback from the 7-day branch.
- Decide which cockpit capabilities should be ported to `main` without restoring 5-hour UI in this branch.
- Add export/import only if a concrete migration need is confirmed.

## Explicit Non-Goals

- Project, conversation, tool, or skill leaderboards.
- Cloud sync, telemetry, account billing APIs, or invoice claims.
- Hardware monitoring, auto-update, LaunchAgent, or background daemon.
- Direct dependency on codexU caches or databases.
