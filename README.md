# Hermes Mobile Desktop

Run the genuine [Hermes Agent](https://github.com/NousResearch/Hermes-Agent) Desktop renderer as a private, phone-friendly web application.

This is not a replacement dashboard and it is not a remote video stream. It adapts Hermes Desktop's existing React renderer for browsers, preserves the real session, file, review, and composer workflows, and proxies them to a dedicated loopback-only Hermes gateway. Connection settings remain deployment-managed and fail closed in the browser instead of reporting changes that were not applied.

## What it adds

- Browser implementation of the Electron preload contract
- Same-origin REST and WebSocket gateway access
- 390px phone layout with pane overlays and safe-area handling
- Explicit 44px Send and navigation targets
- Touch Return inserts a newline; Send remains explicit
- Responsive settings, intro, titlebar, and virtual-keyboard behavior
- Reproducible systemd, Caddy, and Tailscale deployment
- Playwright desktop/mobile QA and a real chat smoke test

## Browser capability boundary

The browser bridge implements the renderer contract without type suppression. Session, composer, file browsing, previews, and Git review operations use the authenticated gateway. Connection settings are visible but deployment-managed; save, apply, test, and OAuth mutations reject explicitly. Electron-only capabilities cannot be made safe in a browser: the integrated PTY, desktop self-update/uninstall, pet overlay, and VS Code Marketplace theme download are present as fail-closed adapters and report that they are unavailable instead of crashing or mutating the host.

## Security model

The gateway and Caddy listeners bind only to `127.0.0.1`. Use Tailscale Serve for private HTTPS ingress. Do not expose this service with Tailscale Funnel or a public reverse proxy.

The generated browser document contains a dedicated gateway token so the Desktop renderer can authenticate. Anyone who can load the site can recover that token and act with the gateway's authority. Restrict access with tailnet ACLs and treat the URL as a privileged operator surface.

See [docs/SECURITY.md](docs/SECURITY.md).

## Requirements

- Linux with user systemd
- Hermes Agent already installed and working
- Git, Node.js 20.19+ or 22.12+, npm, Python 3
- Caddy
- Tailscale for private HTTPS access

On a headless host where the user manager must survive logout, enable lingering once with `sudo loginctl enable-linger "$USER"`.

## Install

```bash
git clone git@github.com:Psybion/hermes-desktop-mobile.git
cd hermes-desktop-mobile
./scripts/install.sh
```

The installer:

1. prepares and builds a fresh dedicated Hermes Agent source candidate;
2. pins the tested upstream revision and verifies the patch checksum;
3. stages source, configuration, units, and the renderer helper before changing the installed release;
4. creates a random gateway token through a mode-`0600` atomic replacement;
5. renders user-local Caddy and systemd configuration;
6. starts the gateway with the pinned checkout first on `PYTHONPATH`;
7. rejects startup unless the authenticated gateway reports the exact tested baseline and capabilities, then restores the complete previous release if activation fails.

It does not modify or push the installed NousResearch checkout.

For packaging or dry-run validation, `./scripts/install.sh --no-start` prepares, builds, renders, and validates an isolated candidate without changing the installed release or service state.

### Adopt a legacy installation

A Desktop Web release installed before this package is deliberately treated as unowned and will not be overwritten by the normal installer. The one-time migration is limited to the known legacy loopback gateway, Caddy configuration, and two user units; any other shape is refused without modification.

First run the non-activating preflight:

```bash
./scripts/install.sh --adopt-existing --no-start
```

Then, after reviewing the candidate and accepting a brief managed-service restart, activate it:

```bash
./scripts/install.sh --adopt-existing
```

The installer validates the new candidate before stopping services, retains the original legacy configuration and units in a private `legacy-migration-backup.*` directory under the new package prefix, and restores the exact old release if candidate activation fails.

Expose the loopback service privately:

```bash
./scripts/expose-tailscale.sh 8457 9122
```

Tailscale prints the HTTPS URL. Keep it tailnet-only.

## Verify

```bash
npm ci
npx playwright install chromium
./scripts/verify.sh
```

Against a Tailscale URL:

```bash
HERMES_DESKTOP_WEB_URL=https://your-device.your-tailnet.ts.net:8457 npm run qa
HERMES_DESKTOP_WEB_URL=https://your-device.your-tailnet.ts.net:8457 npm run qa:pane
```

The chat smoke test submits a real agent turn and may incur provider usage:

```bash
HERMES_DESKTOP_WEB_URL=https://your-device.your-tailnet.ts.net:8457 npm run qa:chat
```

Screenshots are written to `qa-output/` and ignored by Git.

## Source compatibility

The browser adaptation is a minimal patch against the exact Hermes Agent revision recorded in `patches/BASELINE`. The dedicated gateway also imports from that checkout, while the installed Hermes environment supplies the Python interpreter and dependencies. Installations fail closed unless the running gateway reports the same tested baseline and browser capabilities. Updating the host Hermes CLI alone does not update this client; update this package to a reviewed baseline and rerun `./scripts/ci.sh`.

## Operations

```bash
systemctl --user status hermes-desktop-web-gateway.service hermes-desktop-web.service
systemctl --user restart hermes-desktop-web-gateway.service hermes-desktop-web.service
journalctl --user -u hermes-desktop-web-gateway.service -u hermes-desktop-web.service
./scripts/verify.sh
```

See [docs/OPERATIONS.md](docs/OPERATIONS.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and the [initial verification record](docs/VERIFICATION.md).

## Uninstall

```bash
./scripts/uninstall.sh
./scripts/uninstall.sh --purge  # also removes generated config, token, source, and build
```

Tailscale Serve is managed separately so uninstalling cannot erase unrelated Serve routes.

## License

This packaging and adaptation are MIT licensed. Hermes Agent is also distributed under the MIT license and remains copyright Nous Research. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the retained upstream notice.
