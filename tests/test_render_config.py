#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("render_config", ROOT / "scripts" / "render_config.py")
assert SPEC and SPEC.loader
render_config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(render_config)


class RenderConfigTests(unittest.TestCase):
    def test_absolute_rejects_caddy_placeholder_braces(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            with self.assertRaisesRegex(ValueError, "braces"):
                render_config.absolute(str(Path(raw_tmp) / "{env.HOME}"))

    def test_private_write_is_restrictive_before_atomic_publish(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            target = Path(raw_tmp) / "env"
            real_replace = os.replace
            observed: dict[str, object] = {}

            def inspect_replace(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
                source_path = Path(source)
                observed["mode"] = stat.S_IMODE(source_path.stat().st_mode)
                observed["target_existed"] = target.exists()
                real_replace(source, destination)

            previous_umask = os.umask(0o022)
            try:
                with mock.patch.object(os, "replace", side_effect=inspect_replace):
                    render_config.write_private_text(target, 'TOKEN="secret"\n')
            finally:
                os.umask(previous_umask)

            self.assertEqual(observed, {"mode": 0o600, "target_existed": False})
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(target.read_text(encoding="utf-8"), 'TOKEN="secret"\n')

    def test_private_write_rejects_symlink_target(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp_path = Path(raw_tmp)
            outside = tmp_path / "outside"
            outside.write_text("keep", encoding="utf-8")
            target = tmp_path / "env"
            target.symlink_to(outside)

            with self.assertRaisesRegex(ValueError, "regular file"):
                render_config.write_private_text(target, 'TOKEN="secret"\n')

            self.assertEqual(outside.read_text(encoding="utf-8"), "keep")


if __name__ == "__main__":
    unittest.main()
