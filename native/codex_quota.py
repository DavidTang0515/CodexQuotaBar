#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import select
import shutil
import signal
import subprocess
import sys
import time


TIMEOUT_SECONDS = 5
CLIENT_INFO = {"name": "codex-quota-bar", "title": "CodexQuotaBar", "version": "0.1.0"}


class QuotaError(Exception):
    pass


def find_codex() -> str | None:
    found = shutil.which("codex")
    if found:
        return found

    for candidate in (
        pathlib.Path("/Applications/Codex.app/Contents/Resources/codex"),
        pathlib.Path.home() / "Applications/Codex.app/Contents/Resources/codex",
    ):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)

    return None


def codex_env() -> dict[str, str]:
    home = str(pathlib.Path.home())
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    return {
        "CODEX_CI": "1",
        "CODEX_HOME": os.environ.get("CODEX_HOME") or str(pathlib.Path(home) / ".codex"),
        "CODEX_SHELL": "1",
        "HOME": os.environ.get("HOME") or home,
        "LOGNAME": os.environ.get("LOGNAME") or user,
        "PATH": os.environ.get("PATH")
        or "/Applications/Codex.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "SHELL": os.environ.get("SHELL") or "/bin/zsh",
        "TMPDIR": os.environ.get("TMPDIR") or "/tmp",
        "USER": user,
    }


def stop_process(proc: subprocess.Popen) -> None:
    running = proc.poll() is None
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except OSError:
        if running:
            proc.terminate()

    if running:
        try:
            proc.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            pass

    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except OSError:
        if running:
            proc.kill()


def pick(data: dict, *keys: str):
    for key in keys:
        value = data.get(key)
        if value is not None:
            return value
    return None


def select_codex_bucket(result: dict) -> dict:
    by_id = result.get("rateLimitsByLimitId")
    if isinstance(by_id, dict):
        for key, bucket in by_id.items():
            if isinstance(bucket, dict) and str(key).lower() == "codex":
                return bucket
        for key, bucket in by_id.items():
            if not isinstance(bucket, dict):
                continue
            limit_id = str(pick(bucket, "limitId", "limit_id") or "").lower()
            limit_name = str(pick(bucket, "limitName", "limit_name") or "").lower()
            if limit_id.startswith("codex") or "codex" in limit_name:
                return bucket

    rate_limits = result.get("rateLimits")
    if isinstance(rate_limits, dict):
        return rate_limits

    return {}


def normalize_window(window: dict | None) -> dict | None:
    if not isinstance(window, dict):
        return None
    used = pick(window, "usedPercent", "used_percent")
    if used is None:
        return None
    try:
        used_float = float(used)
    except (TypeError, ValueError):
        return None
    left = max(0, min(100, round(100 - used_float)))
    return {
        "usedPercent": used_float,
        "leftPercent": left,
        "resetsAt": normalize_time(pick(window, "resetsAt", "resets_at")),
        "windowMinutes": pick(window, "windowDurationMins", "window_minutes"),
    }


def normalize_time(value) -> str | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(value)))
        except (OverflowError, OSError, ValueError):
            return str(value)
    return str(value)


def normalize(bucket: dict) -> dict:
    primary = normalize_window(bucket.get("primary"))
    secondary = normalize_window(bucket.get("secondary"))
    return {
        "ok": bool(primary or secondary),
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "codex_app_server",
        "plan": pick(bucket, "planType", "plan_type", "plan"),
        "fiveHourLeft": primary.get("leftPercent") if primary else None,
        "sevenDayLeft": secondary.get("leftPercent") if secondary else None,
        "fiveHourReset": primary.get("resetsAt") if primary else None,
        "sevenDayReset": secondary.get("resetsAt") if secondary else None,
    }


def read_quota() -> dict:
    codex = find_codex()
    if not codex:
        raise QuotaError("Codex CLI not found. Open Codex or install the Codex CLI.")

    proc = subprocess.Popen(
        [codex, "app-server", "--listen", "stdio://"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=codex_env(),
        start_new_session=True,
    )

    try:
        if proc.stdin is None or proc.stdout is None:
            raise QuotaError("Codex app-server pipes unavailable.")

        messages = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": CLIENT_INFO,
                    "capabilities": {"experimentalApi": True, "requestAttestation": False},
                },
            },
            {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": None},
        ]

        for message in messages:
            proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            proc.stdin.flush()

        deadline = time.monotonic() + TIMEOUT_SECONDS
        tail: list[str] = []
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise QuotaError("Codex app-server exited: " + "".join(tail[-3:]).strip())

            ready, _, _ = select.select([proc.stdout], [], [], 0.1)
            if not ready:
                continue

            line = proc.stdout.readline()
            if not line:
                continue
            tail.append(line)

            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue

            if message.get("id") != 2:
                continue
            if "error" in message:
                raise QuotaError(str(message["error"]))

            bucket = select_codex_bucket(message.get("result") or {})
            if not bucket:
                raise QuotaError("Codex app-server returned no quota data.")
            snapshot = normalize(bucket)
            if not snapshot["ok"]:
                raise QuotaError("Codex app-server returned unreadable quota data.")
            return snapshot

        raise QuotaError("Codex quota request timed out.")
    finally:
        stop_process(proc)


def main() -> int:
    try:
        payload = read_quota()
    except Exception as exc:
        payload = {
            "ok": False,
            "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "source": "unavailable",
            "error": str(exc),
            "fiveHourLeft": None,
            "sevenDayLeft": None,
            "fiveHourReset": None,
            "sevenDayReset": None,
        }

    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
