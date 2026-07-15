#!/usr/bin/env python3
"""Fail closed unless the running gateway matches the pinned browser baseline."""

from __future__ import annotations

import argparse
import json
import shlex
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REQUIRED_CAPABILITIES = {"browser-bridge-v1", "git-base-branches"}


def session_token(env_file: Path) -> str:
    for raw in env_file.read_text(encoding="utf-8").splitlines():
        key, separator, value = raw.partition("=")
        if separator and key.strip() == "HERMES_DASHBOARD_SESSION_TOKEN":
            parsed = shlex.split(value, posix=True)
            if len(parsed) == 1 and parsed[0]:
                return parsed[0]
    raise RuntimeError(f"Gateway token is missing from {env_file}")


def verify(url: str, env_file: Path, baseline: str, timeout: float = 30) -> dict[str, Any]:
    token = session_token(env_file)
    endpoint = f"{url.rstrip('/')}/api/desktop-web/compat"
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None

    while time.monotonic() < deadline:
        request = urllib.request.Request(endpoint, headers={"X-Hermes-Session-Token": token})
        try:
            with urllib.request.urlopen(request, timeout=min(2.0, max(0.1, timeout))) as response:
                payload = json.load(response)
            if payload.get("baseline") != baseline:
                raise RuntimeError(
                    f"Gateway baseline mismatch: expected {baseline}, received {payload.get('baseline')!r}"
                )
            capabilities = set(payload.get("capabilities") or [])
            missing = sorted(REQUIRED_CAPABILITIES - capabilities)
            if missing:
                raise RuntimeError(f"Gateway capability mismatch: missing {', '.join(missing)}")
            return payload
        except RuntimeError:
            raise
        except (OSError, ValueError, urllib.error.HTTPError, urllib.error.URLError) as exc:
            last_error = exc
            time.sleep(0.25)

    raise RuntimeError(f"Pinned gateway compatibility probe failed: {last_error}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    payload = verify(args.url, args.env_file, args.baseline, args.timeout)
    print(f"Verified pinned Hermes gateway baseline {payload['baseline']}")


if __name__ == "__main__":
    main()
