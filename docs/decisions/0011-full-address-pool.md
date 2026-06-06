# 11. Pool bounds are full 127/8 addresses, not one /24's last octet

**Status**: Accepted (2026-08-03)

## Context
`DEVIP_POOL_START/END` were single last-octet integers (`10`/`99`), confining
the pool to `127.0.0.0/24` — 253 usable of the 16M in `127.0.0.0/8`. ADR-0005
deferred widening it, citing "32-bit IP math in bash 3.2" and "unbounded
pf-anchor growth." The math is tractable; the anchor growth is the real limit.

## Decision
Bounds accept **a bare octet (shorthand for `127.0.0.N`, back-compat) or a full
`127.x.x.x` address** (`_pool_addr`). Iteration is over 32-bit integers
(`ip_to_int`/`int_to_ip`), so the pool can span anywhere in `127/8`. Validation
(`_pool_bounds`, `_valid_pool_ip`): both bounds in `127.0.0.2 .. 127.255.255.254`,
start ≤ end, and the range size ≤ `DEVIP_POOL_MAX` (default 65536) — because
`provision` renders one pf rule + one `lo0` alias per pool IP, so an unbounded
range would blow up the anchor and the boot daemon. Default stays `10`/`99`.
`DEVIP_POOL_MAX` is a config key (`pool_max`).

## Alternatives considered
- Full IPs only (no bare-int shorthand) — breaks the terse common form and
  existing configs. Kept both; a bare int is just `127.0.0.N`.
- Render only *allocated* IPs so the range could be truly unbounded — would make
  every `dev-ip ip` require sudo to add its alias/rule, breaking the "allocation
  is an instant, sudo-free file write" property. Rejected; capped instead.
- Allow non-127 addresses — aliasing them on `lo0` would hijack routing to real
  hosts. Hard-limited to `127/8`.

## Consequences
The whole loopback `/8` is usable — place or size the pool anywhere (e.g.
`127.<team>.<x>.<y>`), not boxed into one `/24`. Cost scales with range *size*,
not representation, and is capped. Supersedes ADR-0005's `/24` confinement and
its 32-bit-math deferral (0005's pool-range decision otherwise stands).
