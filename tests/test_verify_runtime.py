from __future__ import annotations

import importlib.util
import json
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("verify_runtime", ROOT / "scripts" / "verify_runtime.py")
assert SPEC and SPEC.loader
verify_runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify_runtime)


class Handler(BaseHTTPRequestHandler):
    baseline = "expected-baseline"
    capabilities = ["browser-bridge-v2", "git-base-branches"]

    def do_GET(self) -> None:
        if self.path != "/api/desktop-web/compat" or self.headers.get("X-Hermes-Session-Token") != "test-token":
            self.send_response(403)
            self.end_headers()
            return
        body = json.dumps(
            {
                "baseline": self.baseline,
                "capabilities": self.capabilities,
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        del format, args


class RuntimeCompatibilityTest(unittest.TestCase):
    def setUp(self) -> None:
        Handler.baseline = "expected-baseline"
        Handler.capabilities = ["browser-bridge-v2", "git-base-branches"]
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.temp = tempfile.TemporaryDirectory()
        self.env_file = Path(self.temp.name) / "env"
        token_key = "HERMES_DASHBOARD_SESSION_" + "TOKEN"
        self.env_file.write_text(f'{token_key}="test-token"\n', encoding="utf-8")
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def test_accepts_exact_pinned_runtime(self) -> None:
        payload = verify_runtime.verify(self.url, self.env_file, "expected-baseline", timeout=2)
        self.assertEqual(payload["baseline"], "expected-baseline")

    def test_rejects_gateway_from_another_baseline(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "baseline mismatch"):
            verify_runtime.verify(self.url, self.env_file, "different-baseline", timeout=1)

    def test_rejects_gateway_without_required_capabilities(self) -> None:
        Handler.capabilities = ["browser-bridge-v2"]
        with self.assertRaisesRegex(RuntimeError, "git-base-branches"):
            verify_runtime.verify(self.url, self.env_file, "expected-baseline", timeout=1)

    def test_rejects_legacy_browser_bridge_capability(self) -> None:
        Handler.capabilities = ["browser-bridge-v1", "git-base-branches"]
        with self.assertRaisesRegex(RuntimeError, "browser-bridge-v2"):
            verify_runtime.verify(self.url, self.env_file, "expected-baseline", timeout=1)


if __name__ == "__main__":
    unittest.main()
