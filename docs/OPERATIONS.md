# Operations

## Paths

Defaults can be overridden with environment variables.

| Purpose | Default |
|---|---|
| Dedicated source | `~/.local/share/hermes-mobile-desktop/source` |
| Staged renderer | `~/.local/share/hermes-mobile-desktop/dist` |
| Protected config | `~/.config/hermes-desktop-web` |
| User units | `~/.config/systemd/user/hermes-desktop-web*.service` |
| Local web listener | `127.0.0.1:9122` |
| Dedicated gateway | `127.0.0.1:9131` |

Supported overrides include `HERMES_HOME`, `HERMES_BIN`, `HERMES_SOURCE_ROOT`, `HERMES_DESKTOP_WEB_HOME`, `HERMES_DESKTOP_WEB_CONFIG`, `HERMES_DESKTOP_WEB_PORT`, and `HERMES_DESKTOP_WEB_GATEWAY_PORT`.

`HERMES_DESKTOP_WEB_HOME` must remain a child of the selected XDG data root, and `HERMES_DESKTOP_WEB_CONFIG` must remain a child of the selected XDG config root. If overridden, `HERMES_SOURCE_ROOT` must remain inside `HERMES_DESKTOP_WEB_HOME` so purge ownership stays bounded. Paths containing active Caddy placeholder braces are rejected. The installer claims only new or empty directories, records explicit ownership markers, and refuses non-empty unmanaged directories or colliding unmanaged systemd units. The uninstaller removes only marked on-disk units; it handles an active or enabled missing-file unit only when both package-directory markers independently prove ownership. `--purge` additionally requires those valid directory markers. Uninstall and activation rollback preserve package files unless both managed services are proven inactive.

For user services that must remain active after logout, check `loginctl show-user "$USER" -p Linger` and enable lingering once with `sudo loginctl enable-linger "$USER"` if needed.

## Rebuild

Rerunning `./scripts/install.sh` prepares a complete pinned candidate without modifying the active release. After source, configuration, Caddy, and unit validation, the installer stops both loaded managed services, including an active or enabled old service whose unit file is missing when package markers prove ownership, and transactionally replaces the package tree, protected configuration, and both units. Their sibling backups are deleted only after service activation and authenticated gateway verification succeed. An activation error or termination signal proves both services inactive, restores every previous component, reloads systemd, and restores each previous unit's enabled and active state. If only post-verification backup deletion fails, the verified new release remains active; the installer reports the retained marker-protected backup, and `uninstall.sh --purge` removes it. The existing gateway token is preserved. `./scripts/install.sh --no-start` performs candidate validation only and leaves installed files and service state unchanged.

## Logs

```bash
journalctl --user -u hermes-desktop-web-gateway.service -f
journalctl --user -u hermes-desktop-web.service -f
```

## Health

```bash
./scripts/verify.sh
systemctl --user is-active hermes-desktop-web-gateway.service hermes-desktop-web.service
sudo tailscale serve status
```

## Disable

```bash
systemctl --user disable --now hermes-desktop-web.service hermes-desktop-web-gateway.service
```

Tailscale Serve configuration is intentionally not reset by installer or uninstaller because one device may host unrelated routes. Remove only the route you created using the current Tailscale CLI's `serve clear` or equivalent command.
