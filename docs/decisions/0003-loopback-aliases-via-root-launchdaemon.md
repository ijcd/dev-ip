# 3. Loopback aliases via a root LaunchDaemon (stock Mac)

**Status**: Accepted (2026-07-15)

## Context
The IP pool (`127.0.0.10-99`) must exist as `lo0` aliases, persisted across reboot, on a stock (non-nix) Mac. `ifconfig lo0 alias` requires root.

## Decision
Install `/Library/LaunchDaemons/dev-ip-loopback.plist` (root domain, `RunAtLoad`) — `render_loopback_plist` in `lib/dev-ip-lib.sh`, `step_loopback` in `bin/dev-ip`. Skipped when `loopback_owner = system` (ADR-0009); default `dev-ip` installs it.

## Alternatives considered
- User LaunchAgent — runs in the user domain, can't run `ifconfig lo0 alias` (needs root).
- Sudo-at-provision-time only, no persisted daemon — aliases don't survive reboot.

## Consequences
Provision step 1 needs sudo on a stock Mac (one of two stock-only sudo steps, with ADR-0004's resolver step 5). Originally mirrored nix's `com.local.loopback-aliases` daemon shape to avoid conflict; post-ADR-0009, dev-ip's daemon is independently labelled (`dev-ip-loopback`), safe alongside an external manager. See `docs/architecture/overview.md` for how this fits the full provision pipeline; ADR-0004 covers why dev-ip's DNS side is also isolated; ADR-0009 covers the ownership model.
