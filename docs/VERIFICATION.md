# Verification record

Date: 2026-07-21

This record describes the Quicksilver compatibility release deployed on the local host and committed on `feat/quicksilver-desktop-port`. It is not merged to the default branch or tagged as a public release. CI repeats the source-level checks from a clean pinned checkout.

## Package integrity

- shell syntax, Python compilation, and Node syntax: passed
- patch SHA-256 and per-file manifest verification: passed
- installer ownership, guarded purge, runtime pinning, and compatibility verifier tests: passed
- machine-specific path and common secret-pattern scan: passed in the clean CI copy
- `npm ci` reported 7 inherited dependency advisories (1 low, 5 high, 1 critical); no automatic dependency remediation was applied as part of this compatibility port

## Clean-room source verification

Baseline: `73c8d40464ad551c9e198ad6e32de8f994f0e10d`

Command: `npm run test:source`

Results:

- pinned upstream fetch, patch application, per-file verification, and repeat application: passed
- Desktop TypeScript checks: passed
- ESLint over every changed Desktop source/test file: passed
- targeted UI tests: 54 passed in 10 files, including browser popup failure reporting, explicit browser Send behavior, mobile Enter-to-newline handling, fail-closed deployment-managed settings, and remote-aware base-branch routing
- Desktop platform tests: 662 passed, 2 skipped in 58 files
- production Vite/Electron build and artifact assertion: passed

The pinned upstream revision itself has unrelated full-tree ESLint findings, so CI scopes ESLint to every file changed by this repository instead of claiming a globally clean upstream tree.

## Installer dry run

Command: `./scripts/install.sh --no-start` with isolated `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, package/config roots, and loopback ports.

Results:

- exact pinned source fetch, patch checksum, per-file integrity, and renderer build: passed
- generated systemd user units and Caddy configuration: passed validation
- temporary candidate/configuration cleanup: verified
- installed release, systemd unit state, and live Caddy/gateway processes: unchanged

## Legacy-install adoption validation

The pre-package Desktop Web release on this host is intentionally unowned: it has the expected loopback Caddy/gateway topology but no package prefix or ownership markers. The installer now requires explicit `--adopt-existing` for only that known legacy shape.

- `tests/upgrade.sh`: passed, including an unowned legacy fixture, non-activating adoption dry run, successful managed activation with retained legacy snapshot, and forced candidate-restart rollback to byte-identical legacy config and units
- `./scripts/install.sh --adopt-existing --no-start`: passed against the actual legacy installation on this host
- exact source pin, integrity manifests, renderer build, generated units, and generated Caddy configuration: passed
- post-run proof: both legacy user services remained active/enabled; no managed package prefix, config marker, or managed-unit marker was created

The authorized adoption cutover was completed after the production activation checks described below.

## Live-runtime acceptance boundary

A temporary loopback-only gateway and Caddy renderer were started on distinct QA ports, using the candidate source and generated private configuration. They reported the exact baseline and all required browser capabilities: `browser-bridge-v2`, `git-base-branches`, and `layout-tree-narrow-overlays`.

Playwright browser QA passed against that temporary runtime:

- desktop bridge contract, fail-closed update adapter, and named session pop-out reuse: passed
- 390px touch viewport: no console/page/network errors, no horizontal overflow, 44px Send target, touch Enter newline, settings bounds, and hidden desktop status bar: passed
- current layout-tree session sidebar: mounts at 236px and detaches cleanly on close
- current Right sidebar/file overlay: opens at `x=154`, width 236px, preserves the 390px composer root, and detaches cleanly on close
- deployed browser QA captured desktop and 390px phone screenshots under `qa-output/`, including the open Right sidebar

No real chat turn was submitted: `npm run qa:chat` can consume provider usage and create a persistent session turn, so it remains an explicit operator action.

## Production adoption and recovery proof

The authorized `./scripts/install.sh --adopt-existing` cutover was exercised against the live legacy installation.

- first attempt: failed closed because the candidate source did not contain the gateway's required `hermes_cli/web_dist`; the installer restored the unowned legacy config, units, and active/enabled service state
- corrective coverage: `tests/upgrade.sh` now requires the installer to install the `web` workspace, build its bundle, and assert `hermes_cli/web_dist/index.html`; clean-room source CI builds the same artifact
- second attempt: the candidate gateway started, but the runtime verifier still required retired capability `browser-bridge-v1`; the installer again restored the complete legacy release
- corrective coverage: the verifier now requires `browser-bridge-v2`, and its test suite rejects a v1-only gateway
- final attempt: activation passed the exact-baseline and capability probe, committed the managed release, and retained the original legacy configuration and units in the private `legacy-migration-backup.*` directory

Post-deployment `./scripts/verify.sh` passed:

- both managed user units are active and enabled, with package ownership headers
- package and config ownership markers are present
- gateway baseline is exactly `73c8d40464ad551c9e198ad6e32de8f994f0e10d`
- capabilities include `browser-bridge-v2`, `git-base-branches`, and `layout-tree-narrow-overlays`
- authenticated renderer/backend reachability and Playwright browser QA passed
- 390px geometry reported no horizontal overflow, a 236px session sidebar, and a 44px Send target
- Right sidebar regression reported `x=154`, width 236px, and clean detachment on close

No real provider chat turn was submitted during deployment verification.
