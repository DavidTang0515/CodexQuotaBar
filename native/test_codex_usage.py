#!/usr/bin/env python3
import datetime as dt
import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import codex_usage


class TokenDeltaTests(unittest.TestCase):
    def test_delta_normalizes_cumulative_snapshots(self):
        previous = {key: 10 for key in codex_usage.TOKEN_KEYS}
        current = {key: 15 for key in codex_usage.TOKEN_KEYS}
        self.assertEqual(
            codex_usage.token_delta(current, previous),
            {key: 5 for key in codex_usage.TOKEN_KEYS},
        )

    def test_reset_uses_new_snapshot(self):
        previous = {key: 20 for key in codex_usage.TOKEN_KEYS}
        current = {key: 3 for key in codex_usage.TOKEN_KEYS}
        self.assertEqual(codex_usage.token_delta(current, previous), current)


class ParserTests(unittest.TestCase):
    def test_session_assigns_deltas_to_current_model(self):
        rows = [
            {"type": "session_meta", "payload": {"id": "session-1"}, "timestamp": "2026-08-01T00:00:00Z"},
            {"type": "turn_context", "payload": {"model": "gpt-5.6-luna"}, "timestamp": "2026-08-01T00:00:01Z"},
            {
                "type": "event_msg",
                "timestamp": "2026-08-01T00:00:02Z",
                "payload": {"type": "token_count", "info": {"total_token_usage": {
                    "input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20,
                    "reasoning_output_tokens": 5, "total_tokens": 120,
                }}},
            },
            {
                "type": "event_msg",
                "timestamp": "2026-08-01T00:00:03Z",
                "payload": {"type": "token_count", "info": {"total_token_usage": {
                    "input_tokens": 150, "cached_input_tokens": 60, "output_tokens": 35,
                    "reasoning_output_tokens": 8, "total_tokens": 185,
                }}},
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "rollout.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            session_id, events = codex_usage.parse_session(path)
        self.assertEqual(session_id, "session-1")
        self.assertEqual(len(events), 2)
        self.assertEqual(events[1]["model"], "gpt-5.6-luna")
        self.assertEqual(events[1]["input_tokens"], 50)
        self.assertEqual(events[1]["cached_input_tokens"], 20)
        self.assertEqual(events[1]["output_tokens"], 15)
        self.assertEqual(events[1]["total_tokens"], 65)

    def test_first_snapshot_uses_first_turn_model_when_context_arrives_later(self):
        rows = [
            {
                "type": "event_msg",
                "timestamp": "2026-08-01T00:00:02Z",
                "payload": {"type": "token_count", "info": {"total_token_usage": {
                    "input_tokens": 10, "cached_input_tokens": 2, "output_tokens": 3,
                    "reasoning_output_tokens": 1, "total_tokens": 13,
                }}},
            },
            {"type": "turn_context", "payload": {"model": "gpt-5.5"}, "timestamp": "2026-08-01T00:00:03Z"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "rollout.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            _, events = codex_usage.parse_session(path)
        self.assertEqual(events[0]["model"], "gpt-5.5")

    def test_thread_index_supplies_model_when_turn_context_is_missing(self):
        rows = [
            {"type": "session_meta", "payload": {"id": "session-2"}, "timestamp": "2026-08-01T00:00:00Z"},
            {
                "type": "event_msg",
                "timestamp": "2026-08-01T00:00:02Z",
                "payload": {"type": "token_count", "info": {"total_token_usage": {
                    "input_tokens": 10, "cached_input_tokens": 2, "output_tokens": 3,
                    "reasoning_output_tokens": 1, "total_tokens": 13,
                }}},
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "rollout.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            _, events = codex_usage.parse_session(path, {"session-2": "gpt-5.6-terra"})
        self.assertEqual(events[0]["model"], "gpt-5.6-terra")

    def test_index_skips_unchanged_file_and_removes_missing_file(self):
        row = {
            "type": "event_msg",
            "timestamp": "2026-08-01T00:00:02Z",
            "payload": {"type": "token_count", "info": {"total_token_usage": {
                "input_tokens": 10, "cached_input_tokens": 2, "output_tokens": 3,
                "reasoning_output_tokens": 1, "total_tokens": 13,
            }}},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "rollout.jsonl"
            path.write_text(json.dumps(row), encoding="utf-8")
            connection = codex_usage.open_database(root / "usage.sqlite")
            first = codex_usage.refresh_index(connection, [path])
            second = codex_usage.refresh_index(connection, [path])
            removed = codex_usage.refresh_index(connection, [])
            event_count = connection.execute("SELECT COUNT(*) FROM usage_events").fetchone()[0]
            connection.close()
        self.assertEqual(first["changedFiles"], 1)
        self.assertEqual(second["changedFiles"], 0)
        self.assertEqual(removed["indexedFiles"], 0)
        self.assertEqual(event_count, 0)


class PricingTests(unittest.TestCase):
    def test_parses_official_markdown_table(self):
        markdown = """
| Metric | Price | Unit |
| --- | ---: | --- |
| Input | $5 | 1M tokens |
| Cached input | $0.5 | 1M tokens |
| Output | $30 | 1M tokens |
"""
        self.assertEqual(codex_usage.parse_pricing_markdown(markdown), (5.0, 0.5, 30.0))

    def test_unknown_model_is_unpriced(self):
        now = dt.datetime.now(dt.timezone.utc)
        connection = sqlite3.connect(":memory:")
        connection.row_factory = sqlite3.Row
        connection.execute(
            """CREATE TABLE events(
            occurred_at TEXT, model TEXT, input_tokens INT, cached_input_tokens INT,
            output_tokens INT, reasoning_output_tokens INT, total_tokens INT)"""
        )
        connection.execute(
            "INSERT INTO events VALUES (?, ?, ?, ?, ?, ?, ?)",
            (now.isoformat(), "private-model", 100, 25, 30, 5, 130),
        )
        rows = list(connection.execute("SELECT * FROM events"))
        result = codex_usage.aggregate(rows, {}, None, now)
        self.assertEqual(result["totalTokens"], 130)
        self.assertEqual(result["unpricedTokens"], 130)
        self.assertIsNone(result["estimatedCostUSD"])

    def test_codex_total_excludes_auto_review_and_external_models(self):
        now = dt.datetime.now(dt.timezone.utc)
        connection = sqlite3.connect(":memory:")
        connection.row_factory = sqlite3.Row
        connection.execute(
            """CREATE TABLE events(
            occurred_at TEXT, model TEXT, input_tokens INT, cached_input_tokens INT,
            output_tokens INT, reasoning_output_tokens INT, total_tokens INT)"""
        )
        for model, total in (("gpt-5.5", 100), ("codex-auto-review", 60), ("deepseek-v4-flash", 40)):
            connection.execute(
                "INSERT INTO events VALUES (?, ?, ?, ?, ?, ?, ?)",
                (now.isoformat(), model, total, 0, 0, 0, total),
            )
        rows = list(connection.execute("SELECT * FROM events"))
        result = codex_usage.aggregate(rows, {}, None, now)
        self.assertEqual(result["totalTokens"], 100)
        self.assertEqual([item["model"] for item in result["models"]], ["gpt-5.5"])

    def test_cached_input_is_not_double_priced(self):
        now = dt.datetime.now(dt.timezone.utc)
        connection = sqlite3.connect(":memory:")
        connection.row_factory = sqlite3.Row
        connection.execute(
            """CREATE TABLE events(
            occurred_at TEXT, model TEXT, input_tokens INT, cached_input_tokens INT,
            output_tokens INT, reasoning_output_tokens INT, total_tokens INT)"""
        )
        connection.execute(
            "INSERT INTO events VALUES (?, ?, ?, ?, ?, ?, ?)",
            (now.isoformat(), "gpt-5.6-sol", 1_000_000, 500_000, 1_000_000, 10, 2_000_000),
        )
        rows = list(connection.execute("SELECT * FROM events"))
        prices = {"gpt-5.6-sol": {"input": 5, "cachedInput": 0.5, "output": 30}}
        result = codex_usage.aggregate(rows, prices, None, now)
        self.assertAlmostEqual(result["estimatedCostUSD"], 32.75)

    def test_network_failure_keeps_last_local_prices(self):
        current = codex_usage.seed_price_document()
        current["fetchedAt"] = "2026-08-01T00:00:00Z"
        with tempfile.TemporaryDirectory() as directory, mock.patch(
            "codex_usage.urllib.request.urlopen",
            side_effect=urllib.error.URLError("offline"),
        ):
            result = codex_usage.refresh_prices(pathlib.Path(directory) / "pricing.json", current)
        self.assertEqual(result["status"], "cached")
        self.assertEqual(result["prices"], current["prices"])
        self.assertEqual(len(result["errors"]), len(codex_usage.MODEL_DOCS))


if __name__ == "__main__":
    unittest.main()
