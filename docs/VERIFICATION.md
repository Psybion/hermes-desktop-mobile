# Verification record

Date: 2026-07-15

This record describes the checks run for the current public release. CI repeats the source-level checks from a clean pinned checkout.

## Package integrity

- shell syntax, Python compilation, and Node syntax: passed
- patch SHA-256 verification: passed
- installer ownership, guarded purge, runtime pinning, and compatibility verifier tests: passed
- machine-specific path and common secret-pattern scan: passed
- npm audit: 0 vulnerabilities

## Clean-room source verification

Baseline: `569b912d7d0931c7256e9f5fb326609e9deda377`

Command: `npm run test:source`

Results:

- pinned upstream fetch and patch application: passed
- Desktop TypeScript checks: passed
- ESLint over every changed Desktop source/test file: passed
- targeted UI tests: 74 passed in 12 files, including browser popup failure reporting, focus-only named-session reuse, file-picker cancellation, fail-closed deployment-managed settings, and remote-aware base-branch routing
- Desktop platform tests: 413 passed, 1 skipped in 37 files
- production Vite/Electron build and artifact assertion: passed

The pinned upstream revision itself has unrelated full-tree ESLint findings, so CI scopes ESLint to every file changed by this repository instead of claiming a globally clean upstream tree.

## Installer dry run

Command: `./scripts/install.sh --no-start` in isolated XDG data/config directories containing spaces and percent signs.

Results:

- dedicated pinned source checkout: passed
- patch checksum and application: passed
- production build: passed
- generated token file is atomically published at mode `0600`
- paths with spaces and systemd specifier characters escaped correctly; active Caddy placeholder braces rejected
- `systemd-analyze --user verify`: passed
- `caddy validate`: passed
- installed files and service state unchanged: confirmed
- installer ownership markers, refusal of unowned loaded services, active and inactive-enabled managed-service discovery with a missing unit file, per-unit state restoration, swap-boundary signal rollback, retained-backup recovery, and guarded uninstall/purge behavior: passed

## Live-runtime acceptance boundary

The public artifact was exercised with `./scripts/install.sh --no-start`; it was not activated as a live service during publication review. This record therefore makes no claim that a currently running host gateway represents the exact release candidate.

After installation, `./scripts/verify.sh` is the required live acceptance command. It verifies the managed units, Caddy configuration, active services, authenticated baseline/capabilities, renderer/backend reachability, and Playwright browser QA. The browser lane opens a named session twice in Chromium and fails if the second request creates another page, reloads the existing page, changes its mount/route flags, or restores `window.opener`. Missing Playwright dependencies are a verification failure rather than a skipped success. The optional `npm run qa:chat` lane consumes a configured model turn and remains an explicit operator action.
