# Architecture

```text
Phone or desktop browser
        |
        | private Tailscale HTTPS
        v
Tailscale Serve
        |
        | 127.0.0.1:9122
        v
Caddy
  |-- static patched Hermes Desktop renderer
  `-- /api/* and /api/ws
              |
              | 127.0.0.1:9131
              v
       dedicated Hermes gateway
```

The browser bridge installs `window.hermesDesktop` before React starts. It supplies the API shape normally provided by Electron preload and maps browser-capable operations to same-origin HTTP, WebSocket, Clipboard, Notification, and File APIs. Electron still uses its native preload unchanged.

The source checkout is deliberately separate from the installed Hermes Agent checkout. The installer prepares and builds each pinned candidate in a sibling managed tree, then atomically swaps it into the stable source path. The previous tree is retained until activation and compatibility verification succeed and is restored if activation fails after both managed services are proven inactive. `scripts/prepare_source.sh` fetches the pinned upstream commit, verifies the patch checksum, and applies the adaptation. The gateway unit places the stable checkout first on `PYTHONPATH`, so the gateway REST contract and renderer come from one reviewed revision while the installed Hermes environment supplies the interpreter and dependencies. Installation probes an authenticated compatibility endpoint and fails if the running gateway reports another baseline or lacks required capabilities. `scripts/stage_renderer.py` atomically stages the built renderer and injects the dedicated gateway token at deployment time.

Caddy normalizes loopback proxy headers because the Hermes gateway validates browser origin and host information. Token-bearing SPA responses use `private, no-store`; fingerprinted assets override that default with immutable caching. Both listeners remain loopback-only; Tailscale terminates HTTPS and provides network access control.
