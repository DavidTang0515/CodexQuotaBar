#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import glob
import json
import os
import pathlib
import re
import sqlite3
import sys
import urllib.error
import urllib.request


SCHEMA_VERSION = 1
PRICE_TIMEOUT_SECONDS = 8
MODEL_DOCS = {
    "gpt-5.6-sol": "https://developers.openai.com/api/docs/models/gpt-5.6-sol.md",
    "gpt-5.6-terra": "https://developers.openai.com/api/docs/models/gpt-5.6-terra.md",
    "gpt-5.6-luna": "https://developers.openai.com/api/docs/models/gpt-5.6-luna.md",
    "gpt-5.5": "https://developers.openai.com/api/docs/models/gpt-5.5.md",
    "gpt-5.4": "https://developers.openai.com/api/docs/models/gpt-5.4.md",
    "gpt-5.4-mini": "https://developers.openai.com/api/docs/models/gpt-5.4-mini.md",
    "gpt-5.3-codex": "https://developers.openai.com/api/docs/models/gpt-5.3-codex.md",
    "gpt-5.2": "https://developers.openai.com/api/docs/models/gpt-5.2.md",
}
SEED_PRICES = {
    "gpt-5.6-sol": (5.0, 0.5, 30.0),
    "gpt-5.6-terra": (2.5, 0.25, 15.0),
    "gpt-5.6-luna": (1.0, 0.1, 6.0),
    "gpt-5.5": (5.0, 0.5, 30.0),
    "gpt-5.4": (2.5, 0.25, 15.0),
    "gpt-5.4-mini": (0.75, 0.075, 4.5),
    "gpt-5.3-codex": (1.75, 0.175, 14.0),
    "gpt-5.2": (1.75, 0.175, 14.0),
}
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


def canonical_model(model: str | None) -> str:
    value = (model or "unknown").strip().lower()
    if value == "gpt-5.6":
        return "gpt-5.6-sol"
    for known in sorted(MODEL_DOCS, key=len, reverse=True):
        if value == known or value.startswith(known + "-20"):
            return known
    return value or "unknown"


def is_codex_usage_model(model: str | None) -> bool:
    value = canonical_model(model)
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
                indexed_model = (thread_models or {}).get(session_id)
                if indexed_model:
                    fallback_model = indexed_model
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
        rows = connection.execute(
            "SELECT id, model FROM threads WHERE model IS NOT NULL AND model != ''"
        )
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


def seed_price_document() -> dict[str, object]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "fetchedAt": None,
        "status": "seed",
        "prices": {
            model: {
                "input": values[0],
                "cachedInput": values[1],
                "output": values[2],
                "sourceURL": MODEL_DOCS[model],
            }
            for model, values in SEED_PRICES.items()
        },
    }


def load_prices(path: pathlib.Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, dict) and isinstance(value.get("prices"), dict):
            value["status"] = "cached"
            return value
    except (OSError, json.JSONDecodeError):
        pass
    return seed_price_document()


def parse_pricing_markdown(markdown: str) -> tuple[float, float, float]:
    values: dict[str, float] = {}
    pattern = re.compile(r"^\|\s*(Input|Cached input|Output)\s*\|\s*\$([0-9.]+)\s*\|", re.I)
    for line in markdown.splitlines():
        match = pattern.match(line.strip())
        if match:
            values[match.group(1).lower()] = float(match.group(2))
    if set(values) != {"input", "cached input", "output"}:
        raise ValueError("Official model page did not contain a complete text-token price table.")
    return values["input"], values["cached input"], values["output"]


def refresh_prices(path: pathlib.Path, current: dict[str, object]) -> dict[str, object]:
    prices = dict(current.get("prices") or {})
    errors: list[str] = []
    updated = 0

    def fetch(item: tuple[str, str]) -> tuple[str, str, tuple[float, float, float] | None, str | None]:
        model, url = item
        request = urllib.request.Request(url, headers={"User-Agent": "CodexQuotaBar/0.4"})
        try:
            with urllib.request.urlopen(request, timeout=PRICE_TIMEOUT_SECONDS) as response:
                markdown = response.read().decode("utf-8")
            return model, url, parse_pricing_markdown(markdown), None
        except (OSError, ValueError, UnicodeDecodeError, urllib.error.URLError) as exc:
            return model, url, None, str(exc)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        results = list(executor.map(fetch, MODEL_DOCS.items()))
    for model, url, values, error in results:
        if values is not None:
            input_price, cached_price, output_price = values
            prices[model] = {
                "input": input_price,
                "cachedInput": cached_price,
                "output": output_price,
                "sourceURL": url,
            }
            updated += 1
        elif error:
            errors.append(f"{model}: {error}")
    if updated:
        result = {
            "schemaVersion": SCHEMA_VERSION,
            "fetchedAt": utc_now(),
            "status": "live" if not errors else "partial",
            "prices": prices,
            "errors": errors,
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        return result
    current["status"] = "cached" if current.get("fetchedAt") else "seed"
    current["errors"] = errors
    return current


def parse_timestamp(value: str) -> dt.datetime | None:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def range_start(kind: str, now: dt.datetime) -> dt.datetime | None:
    start_of_today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if kind == "today":
        return start_of_today
    if kind == "7d":
        return start_of_today - dt.timedelta(days=6)
    if kind == "30d":
        return start_of_today - dt.timedelta(days=29)
    if kind == "month":
        return start_of_today.replace(day=1)
    return None


def empty_totals() -> dict[str, int]:
    return {
        "inputTokens": 0,
        "cachedInputTokens": 0,
        "outputTokens": 0,
        "reasoningTokens": 0,
        "totalTokens": 0,
    }


def aggregate(rows: list[sqlite3.Row], prices: dict[str, object], start: dt.datetime | None, now: dt.datetime) -> dict[str, object]:
    totals = empty_totals()
    priced_tokens = 0
    unpriced_tokens = 0
    estimated_cost = 0.0
    models: dict[str, dict[str, object]] = {}
    daily: dict[str, dict[str, object]] = {}

    for row in rows:
        occurred = parse_timestamp(row[0])
        if occurred is None:
            continue
        local_time = occurred.astimezone(now.tzinfo)
        if start is not None and local_time < start:
            continue
        model = str(row[1] or "unknown")
        if not is_codex_usage_model(model):
            continue
        canonical = canonical_model(model)
        input_tokens = int(row[2])
        cached_tokens = min(input_tokens, int(row[3]))
        output_tokens = int(row[4])
        reasoning_tokens = int(row[5])
        total_tokens = int(row[6])

        totals["inputTokens"] += input_tokens
        totals["cachedInputTokens"] += cached_tokens
        totals["outputTokens"] += output_tokens
        totals["reasoningTokens"] += reasoning_tokens
        totals["totalTokens"] += total_tokens

        price = prices.get(canonical)
        event_cost: float | None = None
        if isinstance(price, dict):
            uncached = max(0, input_tokens - cached_tokens)
            event_cost = (
                uncached * float(price.get("input") or 0)
                + cached_tokens * float(price.get("cachedInput") or 0)
                + output_tokens * float(price.get("output") or 0)
            ) / 1_000_000
            estimated_cost += event_cost
            priced_tokens += total_tokens
        else:
            unpriced_tokens += total_tokens

        model_item = models.setdefault(
            model,
            {"model": model, "totalTokens": 0, "estimatedCostUSD": 0.0, "priced": event_cost is not None},
        )
        model_item["totalTokens"] = int(model_item["totalTokens"]) + total_tokens
        if event_cost is not None:
            model_item["estimatedCostUSD"] = float(model_item["estimatedCostUSD"]) + event_cost

        day = local_time.date().isoformat()
        day_item = daily.setdefault(day, {"date": day, "totalTokens": 0, "estimatedCostUSD": 0.0})
        day_item["totalTokens"] = int(day_item["totalTokens"]) + total_tokens
        if event_cost is not None:
            day_item["estimatedCostUSD"] = float(day_item["estimatedCostUSD"]) + event_cost

    model_list = sorted(models.values(), key=lambda item: int(item["totalTokens"]), reverse=True)
    for item in model_list:
        if not item["priced"]:
            item["estimatedCostUSD"] = None
        elif isinstance(item["estimatedCostUSD"], float):
            item["estimatedCostUSD"] = round(item["estimatedCostUSD"], 6)

    return {
        **totals,
        "pricedTokens": priced_tokens,
        "unpricedTokens": unpriced_tokens,
        "estimatedCostUSD": round(estimated_cost, 6) if priced_tokens else None,
        "models": model_list,
        "daily": sorted(daily.values(), key=lambda item: item["date"]),
    }


def build_summary(connection: sqlite3.Connection, price_document: dict[str, object]) -> dict[str, object]:
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
    prices = price_document.get("prices") if isinstance(price_document.get("prices"), dict) else {}
    return {
        kind: aggregate(rows, prices, range_start(kind, now), now)
        for kind in ("today", "7d", "30d", "month", "all")
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--refresh-prices", action="store_true")
    args = parser.parse_args(argv)
    support = support_directory()
    try:
        connection = open_database(support / "usage.sqlite")
        root = codex_home()
        source_status = refresh_index(
            connection, discover_session_files(root), load_thread_models(root)
        )
        price_path = support / "pricing.json"
        price_document = load_prices(price_path)
        if args.refresh_prices:
            price_document = refresh_prices(price_path, price_document)
        result = {
            "schemaVersion": SCHEMA_VERSION,
            "ok": True,
            "updatedAt": utc_now(),
            "error": None,
            "sourceStatus": source_status,
            "pricingStatus": {
                "status": price_document.get("status"),
                "fetchedAt": price_document.get("fetchedAt"),
                "errors": price_document.get("errors") or [],
            },
            "ranges": build_summary(connection, price_document),
        }
        connection.close()
    except Exception as exc:
        result = {
            "schemaVersion": SCHEMA_VERSION,
            "ok": False,
            "updatedAt": utc_now(),
            "error": str(exc),
            "sourceStatus": None,
            "pricingStatus": None,
            "ranges": {},
        }
    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
