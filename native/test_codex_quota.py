#!/usr/bin/env python3
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import codex_quota


class FindCodexTests(unittest.TestCase):
    def test_prefers_executable_override(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = pathlib.Path(directory) / "codex"
            executable.touch(mode=0o700)
            with mock.patch.dict(os.environ, {"CODEX_CLI_PATH": str(executable)}):
                self.assertEqual(codex_quota.find_codex(), str(executable))

    def test_uses_codex_from_path(self):
        with mock.patch.dict(os.environ, {"CODEX_CLI_PATH": ""}), mock.patch(
            "codex_quota.shutil.which", return_value="/usr/local/bin/codex"
        ):
            self.assertEqual(codex_quota.find_codex(), "/usr/local/bin/codex")

    def test_finds_chatgpt_bundled_cli(self):
        expected = "/Applications/ChatGPT.app/Contents/Resources/codex"

        def is_expected(path):
            return str(path) == expected

        with mock.patch.dict(os.environ, {"CODEX_CLI_PATH": ""}), mock.patch(
            "codex_quota.shutil.which", return_value=None
        ), mock.patch("codex_quota.pathlib.Path.is_file", is_expected), mock.patch(
            "codex_quota.os.access", side_effect=lambda path, mode: is_expected(path)
        ):
            self.assertEqual(codex_quota.find_codex(), expected)


class NormalizeTests(unittest.TestCase):
    def test_normalizes_current_rate_limit_shape(self):
        snapshot = codex_quota.normalize(
            {
                "planType": "plus",
                "primary": {"usedPercent": 81, "resetsAt": 1_800_000_000},
                "secondary": {"usedPercent": 13, "resetsAt": 1_900_000_000},
            }
        )

        self.assertTrue(snapshot["ok"])
        self.assertEqual(snapshot["plan"], "plus")
        self.assertEqual(snapshot["fiveHourLeft"], 19)
        self.assertEqual(snapshot["sevenDayLeft"], 87)


if __name__ == "__main__":
    unittest.main()
