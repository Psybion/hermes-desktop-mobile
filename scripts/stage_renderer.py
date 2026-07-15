#!/usr/bin/env python3
"""Atomically stage a built Hermes Desktop renderer for browser delivery."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
from pathlib import Path


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def required(values: dict[str, str], key: str) -> str:
    value = os.environ.get(key) or values.get(key, "")
    if not value:
        raise RuntimeError(f"Missing {key}")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, required=True)
    args = parser.parse_args()
    values = parse_env(args.env_file)

    source = Path(required(values, "HERMES_DESKTOP_WEB_SOURCE_DIST"))
    target = Path(required(values, "HERMES_DESKTOP_WEB_DIST"))
    token = required(values, "HERMES_DASHBOARD_SESSION_TOKEN")
    font_value = os.environ.get("HERMES_DESKTOP_WEB_FONT") or values.get("HERMES_DESKTOP_WEB_FONT", "")
    font_source = Path(font_value) if font_value else None
    font_url = "../../../node_modules/@nous-research/ui/dist/fonts/Collapse-Bold.woff2"

    if not (source / "index.html").is_file():
        raise RuntimeError(f"Hermes Desktop renderer has not been built: {source}")

    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    target.parent.chmod(0o700)
    staging = Path(tempfile.mkdtemp(prefix=".dist-", dir=target.parent))

    try:
        shutil.copytree(source, staging, dirs_exist_ok=True)
        assets = staging / "assets"
        assets.mkdir(exist_ok=True)

        if font_source and font_source.is_file():
            shutil.copy2(font_source, assets / font_source.name)
            for stylesheet in assets.glob("*.css"):
                text = stylesheet.read_text(encoding="utf-8")
                stylesheet.write_text(text.replace(font_url, f"./{font_source.name}"), encoding="utf-8")

        index = staging / "index.html"
        html = index.read_text(encoding="utf-8")
        marker = '<script type="module"'
        if marker not in html:
            raise RuntimeError("Could not locate the Hermes Desktop module script")
        bootstrap = f'<script>window.__HERMES_DESKTOP_TOKEN__={json.dumps(token)};</script>\n    '
        index.write_text(html.replace(marker, bootstrap + marker, 1), encoding="utf-8")

        for directory in [staging, *(path for path in staging.rglob("*") if path.is_dir())]:
            directory.chmod(0o755)
        for path in (path for path in staging.rglob("*") if path.is_file()):
            path.chmod(0o644)

        backup = target.with_name(f"{target.name}.previous")
        if backup.exists():
            shutil.rmtree(backup)
        if target.exists():
            os.replace(target, backup)
        try:
            os.replace(staging, target)
        except Exception:
            if backup.exists() and not target.exists():
                os.replace(backup, target)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


if __name__ == "__main__":
    main()
