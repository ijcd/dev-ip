# 5. Configurable IP pool range

**Status**: Accepted (2026-07-16)

## Context
The pool was hardcoded `127.0.0.10-99` in four sites. On a nix host, nix aliases the *same* `10-99` block, so dev-ip and nix can hand out the same IP; and 90 IPs on one fixed range is inflexible.

## Decision
The pool is a configurable last-octet sub-range within `127.0.0.x`, via `DEVIP_POOL_START` (default `10`) and `DEVIP_POOL_END` (default `99`), validated `2 <= start <= end <= 254` by `_pool_bounds` (`lib/dev-ip-lib.sh`). The four consumers — `next_free_ip`, `render_pf_anchor`, `render_loopback_plist`, `_pool_aliased` — derive from it.

## Alternatives considered
- Keep it hardcoded — collides with nix, no flexibility.
- Cross-`/24` / cross-octet ranges or CIDR — needs 32-bit IP math in bash 3.2 and unbounded pf-anchor growth (a `/16` = 65k rules). Deferred; a single `/24` gives up to 253 IPs, enough for any dev-instance count.
- Auto-alias dev-ip's own range on a nix host — breaks defer-to-nix (ADR-0003).

## Consequences
Default `10-99` unchanged — existing `hosts.d` allocations and tests untouched. On a nix host, a pool outside nix's aliased range resolves but won't route; `doctor` warns (never installs a competing loopback daemon — ADR-0003 holds). See ADR-0004 for the resolver/TLD side and `docs/architecture/overview.md` for the pipeline.
