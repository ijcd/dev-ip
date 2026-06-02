# 3. Loopback aliases via a root LaunchDaemon (stock Mac)

**Status**: Accepted (2026-07-15)

## Context
The IP pool (`127.0.0.10-99`) must exist as `lo0` aliases, persisted across reboot, on a stock (non-nix) Mac. `ifconfig lo0 alias` requires root.

## Decision
Install `/Library/LaunchDaemons/dev-ip-loopback.plist` (root domain, `RunAtLoad`) — `render_loopback_plist` in `lib/dev-ip-lib.sh`, `step_loopback` in `bin/dev-ip`. Skipped entirely when step 1 (`step_classify` in `bin/dev-ip`) detects a nix-managed host via `launchctl print system/com.local.loopback-aliases`.

## Alternatives considered
- User LaunchAgent — runs in the user domain, can't run `ifconfig lo0 alias` (needs root).
- Sudo-at-provision-time only, no persisted daemon — aliases don't survive reboot.

## Consequences
Provision step 2 needs sudo on a stock Mac (one of two stock-only sudo steps, with ADR-0004's resolver step). Mirrors nix's `com.local.loopback-aliases` daemon shape so the two never conflict. See `docs/architecture/overview.md` for how this fits the full provision pipeline; ADR-0004 covers why dev-ip's DNS side is also isolated from nix.
