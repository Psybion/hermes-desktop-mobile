# Security

## Trust boundary

Hermes Mobile Desktop is an operator interface with access to agent sessions, tools, and files exposed by the configured Hermes gateway. It is not a public web application.

- Caddy binds only to `127.0.0.1`.
- The dedicated Hermes gateway binds only to `127.0.0.1`.
- Tailscale Serve is the intended ingress.
- Never use Tailscale Funnel for this service.
- Apply restrictive tailnet ACLs when the tailnet has users or devices that should not control Hermes.

## Gateway token

Installation generates a random token with Python's `secrets` module. It is published to `~/.config/hermes-desktop-web/env` only through an atomic replacement whose temporary file is already mode `0600`, injected into the staged HTML, and never committed. Token-bearing HTML responses use `Cache-Control: private, no-store`; fingerprinted static assets are independently cacheable.

Because the browser must authenticate, authorized clients can inspect the delivered page and recover the token. Network authorization is therefore essential. Rotate it by stopping both services, removing the environment file, rerunning `./scripts/install.sh`, and restarting the services.

## Repository hygiene

- Runtime environment files and screenshots are ignored.
- The package check rejects known machine-specific paths, hostnames, and obvious credential patterns.
- The source patch has a committed SHA-256 checksum.
- Installation fails closed if the pinned upstream revision or patch checksum differs.
- The gateway imports from the pinned checkout and must pass an authenticated baseline/capability probe after startup.
- Install and purge require explicit directory ownership markers; unmanaged systemd unit collisions are preserved and rejected.
- No upstream Git remote is ever pushed by these scripts.

## Reporting

Do not paste gateway tokens, GitHub tokens, environment files, or authenticated browser storage into an issue. Redact credentials as `[REDACTED]`.
