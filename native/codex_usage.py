#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import glob
import json
import os
import pathlib
import sqlite3
import sys


SCHEMA_VERSION = 2
TOKEN_KEYS = (
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def support_directory() -> pathlib.Path:
    override = os.environ.get("CODEX_QUOTA_BAR_SUPPORT_DIR")
    if override:
        return pathlib.Path(override).expanduser()
    return pathlib.Path.home() / "Library" / "Application Support" / "CodexQuotaBar"


def codex_home() -> pathlib.Path:
    return pathlib.Path(os.environ.get("CODEX_HOME") or pathlib.Path.home() / ".codex").expanduser()


def is_codex_usage_model(model: str | None) -> bool:
    value = (model or "unknown").strip().lower()
    return value != "codex-auto-review" and not value.startswith("deepseek")


def token_values(value: object) -> dict[str, int] | None:
    if not isinstance(value, dict):
        return None
    result: dict[str, int] = {}
    for key in TOKEN_KEYS:
        try:
            result[key] = max(0, int(value.get(key) or 0))
        except (TypeError, ValueError):
            result[key] = 0
    return result


def token_delta(current: dict[str, int], previous: dict[str, int] | None) -> dict[str, int]:
    if previous is None or any(current[key] < previous[key] for key in TOKEN_KEYS):
        return current.copy()
    return {key: current[key] - previous[key] for key in TOKEN_KEYS}


def parse_session(
    path: pathlib.Path, thread_models: dict[str, str] | None = None
) -> tuple[str, list[dict[str, object]]]:
    session_id = path.stem
    current_model = "unknown"
    fallback_model = "unknown"
    previous: dict[str, int] | None = None
    events: list[dict[str, object]] = []
    pending_unknown: list[int] = []

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, 1):
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            payload = row.get("payload")
            if not isinstance(payload, dict):
                continue
            row_type = row.get("type")
            if row_type == "session_meta":
                session_id = str(payload.get("id") or payload.get("session_id") or session_id)
                fallback_model = (thread_models or {}).get(session_id, fallback_model)
                continue
            if row_type == "turn_context":
                current_model = str(payload.get("model") or current_model)
                for event_index in pending_unknown:
                    events[event_index]["model"] = current_model
                pending_unknown = []
                continue
            if row_type != "event_msg" or payload.get("type") != "token_count":
                continue
            info = payload.get("info")
            if not isinstance(info, dict):
                continue
            current = token_values(info.get("total_token_usage"))
            if current is None:
                continue
            delta = token_delta(current, previous)
            previous = current
            if not any(delta.values()):
                continue
            timestamp = row.get("timestamp")
            if not isinstance(timestamp, str) or not timestamp:
                continue
            events.append(
                {
                    "eventIndex": line_number,
                    "timestamp": timestamp,
                    "model": current_model,
                    **delta,
                }
            )
            if current_model == "unknown":
                pending_unknown.append(len(events) - 1)
    for event_index in pending_unknown:
        events[event_index]["model"] = fallback_model
    return session_id, events


def open_database(path: pathlib.Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS usage_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_files (
          path TEXT PRIMARY KEY,
          size INTEGER NOT NULL,
          mtime_ns INTEGER NOT NULL,
          session_id TEXT NOT NULL,
          indexed_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_events (
          file_path TEXT NOT NULL,
          event_index INTEGER NOT NULL,
          occurred_at TEXT NOT NULL,
          model TEXT NOT NULL,
          input_tokens INTEGER NOT NULL,
          cached_input_tokens INTEGER NOT NULL,
          output_tokens INTEGER NOT NULL,
          reasoning_output_tokens INTEGER NOT NULL,
          total_tokens INTEGER NOT NULL,
          PRIMARY KEY (file_path, event_index),
          FOREIGN KEY (file_path) REFERENCES usage_files(path) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_usage_events_occurred_at
        ON usage_events(occurred_at);
        """
    )
    connection.execute("PRAGMA foreign_keys=ON")
    stored = connection.execute("SELECT value FROM usage_meta WHERE key = 'schema_version'").fetchone()
    if stored is None or stored[0] != str(SCHEMA_VERSION):
        with connection:
            connection.execute("DELETE FROM usage_events")
            connection.execute("DELETE FROM usage_files")
            connection.execute(
                "INSERT OR REPLACE INTO usage_meta(key, value) VALUES ('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
    return connection


def discover_session_files(root: pathlib.Path) -> list[pathlib.Path]:
    active = glob.glob(str(root / "sessions" / "**" / "rollout-*.jsonl"), recursive=True)
    archived = glob.glob(str(root / "archived_sessions" / "*.jsonl"))
    return sorted({pathlib.Path(path) for path in active + archived})


def load_thread_models(root: pathlib.Path) -> dict[str, str]:
    database = root / "state_5.sqlite"
    if not database.exists():
        return {}
    try:
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        rows = connection.execute("SELECT id, model FROM threads WHERE model IS NOT NULL AND model != ''")
        result = {str(thread_id): str(model) for thread_id, model in rows}
        connection.close()
        return result
    except sqlite3.Error:
        return {}


def refresh_index(
    connection: sqlite3.Connection,
    files: list[pathlib.Path],
    thread_models: dict[str, str] | None = None,
) -> dict[str, object]:
    known = {
        row[0]: (int(row[1]), int(row[2]))
        for row in connection.execute("SELECT path, size, mtime_ns FROM usage_files")
    }
    discovered = {str(path) for path in files}
    changed = 0
    errors: list[str] = []

    for missing in set(known) - discovered:
        with connection:
            connection.execute("DELETE FROM usage_events WHERE file_path = ?", (missing,))
            connection.execute("DELETE FROM usage_files WHERE path = ?", (missing,))

    for path in files:
        try:
            stat = path.stat()
        except OSError as exc:
            errors.append(f"{path.name}: {exc}")
            continue
        key = str(path)
        signature = (stat.st_size, stat.st_mtime_ns)
        if known.get(key) == signature:
            continue
        try:
            session_id, events = parse_session(path, thread_models)
        except OSError as exc:
            errors.append(f"{path.name}: {exc}")
            continue
        with connection:
            connection.execute("DELETE FROM usage_events WHERE file_path = ?", (key,))
            connection.execute(
                """
                INSERT INTO usage_files(path, size, mtime_ns, session_id, indexed_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                  size=excluded.size,
                  mtime_ns=excluded.mtime_ns,
                  session_id=excluded.session_id,
                  indexed_at=excluded.indexed_at
                """,
                (key, stat.st_size, stat.st_mtime_ns, session_id, utc_now()),
            )
            connection.executemany(
                """
                INSERT INTO usage_events(
                  file_path, event_index, occurred_at, model, input_tokens,
                  cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        key,
                        event["eventIndex"],
                        event["timestamp"],
                        event["model"],
                        event["input_tokens"],
                        event["cached_input_tokens"],
                        event["output_tokens"],
                        event["reasoning_output_tokens"],
                        event["total_tokens"],
                    )
                    for event in events
                ],
            )
        changed += 1

    indexed = connection.execute("SELECT COUNT(*) FROM usage_files").fetchone()[0]
    return {
        "discoveredFiles": len(files),
        "indexedFiles": indexed,
        "changedFiles": changed,
        "errors": errors[:5],
    }


def parse_timestamp(value: str) -> dt.datetime | None:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def range_start(kind: str, now: dt.datetime) -> dt.datetime | None:
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if kind == "today":
        return today
    if kind == "7d":
        return today - dt.timedelta(days=6)
    if kind == "30d":
        return today - dt.timedelta(days=29)
    if kind == "month":
        return today.replace(day=1)
    return None


def aggregate(rows: list[sqlite3.Row], start: dt.datetime | None, now: dt.datetime) -> dict[str, int]:
    totals = {
        "inputTokens": 0,
        "cachedInputTokens": 0,
        "outputTokens": 0,
        "reasoningTokens": 0,
        "totalTokens": 0,
    }
    for row in rows:
        occurred = parse_timestamp(row[0])
        if occurred is None or (start is not None and occurred.astimezone(now.tzinfo) < start):
            continue
        if not is_codex_usage_model(str(row[1])):
            continue
        totals["inputTokens"] += int(row[2])
        totals["cachedInputTokens"] += min(int(row[2]), int(row[3]))
        totals["outputTokens"] += int(row[4])
        totals["reasoningTokens"] += int(row[5])
        totals["totalTokens"] += int(row[6])
    return totals


def build_summary(connection: sqlite3.Connection) -> dict[str, dict[str, int]]:
    connection.row_factory = sqlite3.Row
    rows = list(
        connection.execute(
            """
            SELECT occurred_at, model, input_tokens, cached_input_tokens,
                   output_tokens, reasoning_output_tokens, total_tokens
            FROM usage_events ORDER BY occurred_at ASC
            """
        )
    )
    now = dt.datetime.now().astimezone()
    return {kind: aggregate(rows, range_start(kind, now), now) for kind in ("today", "7d", "30d", "month", "all")}


def main() -> int:
    support = support_directory()
    try:
        connection = open_database(support / "usage.sqlite")
        root = codex_home()
        source_status = refresh_index(connection, discover_session_files(root), load_thread_models(root))
        result = {
            "schemaVersion": SCHEMA_VERSION,
            "ok": True,
            "updatedAt": utc_now(),
            "error": None,
            "sourceStatus": source_status,
            "ranges": build_summary(connection),
        }
        connection.close()
    except Exception as exc:
        result = {
            "schemaVersion": SCHEMA_VERSION,
            "ok": False,
            "updatedAt": utc_now(),
            "error": str(exc),
            "sourceStatus": None,
            "ranges": {},
        }
    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
