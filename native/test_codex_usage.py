#!/usr/bin/env python3
import datetime as dt
import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import codex_usage


class TokenDeltaTests(unittest.TestCase):
    def test_delta_normalizes_cumulative_snapshots(self):
        previous = {key: 10 for key in codex_usage.TOKEN_KEYS}
        current = {key: 15 for key in codex_usage.TOKEN_KEYS}
        self.assertEqual(codex_usage.token_delta(current, previous), {key: 5 for key in codex_usage.TOKEN_KEYS})

    def test_reset_uses_new_snapshot(self):
        previous = {key: 20 for key in codex_usage.TOKEN_KEYS}
        current = {key: 3 for key in codex_usage.TOKEN_KEYS}
        self.assertEqual(codex_usage.token_delta(current, previous), current)


class ParserTests(unittest.TestCase):
    def test_session_assigns_deltas_to_current_model(self):
        rows = [
            {"type": "turn_context", "payload": {"model": "gpt-test"}, "timestamp": "2026-08-01T00:00:01Z"},
            {"type": "event_msg", "timestamp": "2026-08-01T00:00:02Z", "payload": {"type": "token_count", "info": {"total_token_usage": {
                "input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20,
                "reasoning_output_tokens": 5, "total_tokens": 120,
            }}}},
            {"type": "event_msg", "timestamp": "2026-08-01T00:00:03Z", "payload": {"type": "token_count", "info": {"total_token_usage": {
                "input_tokens": 150, "cached_input_tokens": 60, "output_tokens": 35,
                "reasoning_output_tokens": 8, "total_tokens": 185,
            }}}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "rollout.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            _, events = codex_usage.parse_session(path)
        self.assertEqual(events[1]["input_tokens"], 50)
        self.assertEqual(events[1]["cached_input_tokens"], 20)
        self.assertEqual(events[1]["output_tokens"], 15)
        self.assertEqual(events[1]["total_tokens"], 65)

    def test_index_skips_unchanged_file_and_removes_missing_file(self):
        row = {"type": "event_msg", "timestamp": "2026-08-01T00:00:02Z", "payload": {"type": "token_count", "info": {"total_token_usage": {
            "input_tokens": 10, "cached_input_tokens": 2, "output_tokens": 3,
            "reasoning_output_tokens": 1, "total_tokens": 13,
        }}}}
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "rollout.jsonl"
            path.write_text(json.dumps(row), encoding="utf-8")
            connection = codex_usage.open_database(root / "usage.sqlite")
            first = codex_usage.refresh_index(connection, [path])
            second = codex_usage.refresh_index(connection, [path])
            removed = codex_usage.refresh_index(connection, [])
            connection.close()
        self.assertEqual(first["changedFiles"], 1)
        self.assertEqual(second["changedFiles"], 0)
        self.assertEqual(removed["indexedFiles"], 0)


class AggregateTests(unittest.TestCase):
    def test_aggregate_keeps_token_components_without_pricing(self):
        now = dt.datetime.now().astimezone()
        connection = sqlite3.connect(":memory:")
        connection.row_factory = sqlite3.Row
        connection.execute(
            "CREATE TABLE events(occurred_at TEXT, model TEXT, input_tokens INT, cached_input_tokens INT, output_tokens INT, reasoning_output_tokens INT, total_tokens INT)"
        )
        connection.execute("INSERT INTO events VALUES (?, ?, ?, ?, ?, ?, ?)", (now.isoformat(), "gpt-test", 100, 40, 20, 5, 120))
        rows = list(connection.execute("SELECT * FROM events"))
        result = codex_usage.aggregate(rows, None, now)
        self.assertEqual(result["inputTokens"], 100)
        self.assertEqual(result["cachedInputTokens"], 40)
        self.assertEqual(result["outputTokens"], 20)
        self.assertEqual(result["totalTokens"], 120)

    def test_excludes_auto_review_and_external_models(self):
        now = dt.datetime.now().astimezone()
        connection = sqlite3.connect(":memory:")
        connection.row_factory = sqlite3.Row
        connection.execute(
            "CREATE TABLE events(occurred_at TEXT, model TEXT, input_tokens INT, cached_input_tokens INT, output_tokens INT, reasoning_output_tokens INT, total_tokens INT)"
        )
        for model, total in (("gpt-test", 100), ("codex-auto-review", 60), ("deepseek-v4-flash", 40)):
            connection.execute("INSERT INTO events VALUES (?, ?, ?, ?, ?, ?, ?)", (now.isoformat(), model, total, 0, 0, 0, total))
        rows = list(connection.execute("SELECT * FROM events"))
        self.assertEqual(codex_usage.aggregate(rows, None, now)["totalTokens"], 100)


if __name__ == "__main__":
    unittest.main()
