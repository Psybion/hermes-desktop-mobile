#!/usr/bin/env python3
"""Render user-local Caddy and systemd configuration without exposing secrets."""

from __future__ import annotations

import argparse
import os
import re
import secrets
import shutil
import tempfile
from pathlib import Path


def parse_env(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = raw.partition("=")
        if separator:
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(source: Path, target: Path, replacements: dict[str, str]) -> None:
    text = source.read_text(encoding="utf-8")
    for key, value in replacements.items():
        text = text.replace(f"@{key}@", value)
    unresolved = sorted(set(re.findall(r"@[A-Z_][A-Z_]*@", text)))
    if unresolved:
        raise RuntimeError(f"Unresolved placeholders in {source}: {', '.join(unresolved)}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def write_private_text(target: Path, text: str) -> None:
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise ValueError(f"Private configuration target must be a regular file: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    temporary_path = Path(temporary)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            descriptor = -1
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, target)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary_path.unlink(missing_ok=True)


def absolute(path: str) -> str:
    result = str(Path(path).expanduser().resolve())
    if (
        any(ord(character) < 32 for character in result)
        or '"' in result
        or "\\" in result
        or "{" in result
        or "}" in result
    ):
        raise ValueError("Paths may not contain control characters, quotes, backslashes, or braces")
    return result


def systemd_path(value: str) -> str:
    safe = "/._-+:@"
    return "".join(
        "%%"
        if character == "%"
        else character
        if character.isalnum() or character in safe
        else f"\\x{ord(character):02x}"
        for character in value
    )


def systemd_value(value: str) -> str:
    if any(ord(character) < 32 for character in value):
        raise ValueError("Systemd values may not contain control characters")
    return value.replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--config-dir", required=True)
    parser.add_argument("--unit-dir", required=True)
    parser.add_argument("--output-config-dir")
    parser.add_argument("--output-unit-dir")
    parser.add_argument("--output-stage-script")
    parser.add_argument("--hermes-home", required=True)
    parser.add_argument("--hermes-bin", required=True)
    parser.add_argument("--caddy-bin", required=True)
    parser.add_argument("--web-port", type=int, default=9122)
    parser.add_argument("--gateway-port", type=int, default=9131)
    args = parser.parse_args()

    if not (1 <= args.web_port <= 65535 and 1 <= args.gateway_port <= 65535):
        raise ValueError("Ports must be between 1 and 65535")
    if args.web_port == args.gateway_port:
        raise ValueError("Web and gateway ports must differ")

    repo_root = Path(absolute(args.repo_root))
    source_root = Path(absolute(args.source_root))
    prefix = Path(absolute(args.prefix))
    config_dir = Path(absolute(args.config_dir))
    unit_dir = Path(absolute(args.unit_dir))
    output_config_dir = Path(absolute(args.output_config_dir or args.config_dir))
    output_unit_dir = Path(absolute(args.output_unit_dir or args.unit_dir))
    hermes_home = absolute(args.hermes_home)
    hermes_bin = absolute(args.hermes_bin)
    caddy_bin = absolute(args.caddy_bin)
    env_file = config_dir / "env"
    caddyfile = config_dir / "Caddyfile"
    output_env_file = output_config_dir / "env"
    output_caddyfile = output_config_dir / "Caddyfile"
    stage_script = prefix / "bin" / "stage_renderer.py"
    output_stage_script = Path(absolute(args.output_stage_script or str(stage_script)))
    dist_root = prefix / "dist"
    source_dist = source_root / "apps" / "desktop" / "dist"
    font = source_root / "node_modules" / "@nous-research" / "ui" / "dist" / "fonts" / "Collapse-Bold.woff2"

    old = parse_env(env_file)
    token = old.get("HERMES_DASHBOARD_SESSION_TOKEN") or secrets.token_urlsafe(48)
    env = {
        "HERMES_DASHBOARD_SESSION_TOKEN": token,
        "HERMES_HOME": hermes_home,
        "HERMES_DESKTOP_WEB_SOURCE_DIST": str(source_dist),
        "HERMES_DESKTOP_WEB_DIST": str(dist_root),
        "HERMES_DESKTOP_WEB_FONT": str(font),
    }

    output_config_dir.mkdir(parents=True, exist_ok=True)
    write_private_text(output_env_file, "".join(f"{key}={quote(value)}\n" for key, value in env.items()))
    output_stage_script.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(repo_root / "scripts" / "stage_renderer.py", output_stage_script)
    output_stage_script.chmod(0o755)

    path_value = os.pathsep.join(dict.fromkeys([str(Path(hermes_bin).parent), *os.environ.get("PATH", "").split(os.pathsep)]))
    replacements = {
        "WEB_PORT": str(args.web_port),
        "GATEWAY_PORT": str(args.gateway_port),
        "DIST_ROOT": str(dist_root),
        "HERMES_HOME": hermes_home,
        "HERMES_HOME_SYSTEMD": systemd_path(hermes_home),
        "ENV_FILE": systemd_value(str(env_file)),
        "ENV_FILE_SYSTEMD": systemd_path(str(env_file)),
        "PATH": systemd_value(path_value),
        "SOURCE_ROOT": systemd_value(str(source_root)),
        "HERMES_BIN": systemd_value(hermes_bin),
        "STAGE_SCRIPT": systemd_value(str(stage_script)),
        "CADDY_BIN": systemd_value(caddy_bin),
        "CADDYFILE": systemd_value(str(caddyfile)),
    }
    render(repo_root / "templates" / "Caddyfile.in", output_caddyfile, replacements)
    render(
        repo_root / "templates" / "hermes-desktop-web-gateway.service.in",
        output_unit_dir / "hermes-desktop-web-gateway.service",
        replacements,
    )
    render(
        repo_root / "templates" / "hermes-desktop-web.service.in",
        output_unit_dir / "hermes-desktop-web.service",
        replacements,
    )

    print(f"Rendered private runtime configuration under {output_config_dir}")


if __name__ == "__main__":
    main()
