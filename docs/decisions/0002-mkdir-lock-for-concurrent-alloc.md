# 2. mkdir-based lock for concurrent alloc

**Status**: Superseded by ADR-0006 (2026-07-29)

## Context
`alloc_ip` on a new name must pick the lowest-free IP and write `hosts.d/<label>` without two concurrent callers racing to the same IP. macOS ships no `flock(1)`.

## Decision
Serialize the allocate-new path with an atomic `mkdir` lock on `hosts.d/.lock` — `_with_lock` (`lib/dev-ip-lib.sh:42-53`) retries with backoff (~5s, 50 × 0.1s) and releases via `trap … RETURN`. The fast path — `hosts.d/<label>` already exists — skips the lock entirely (`alloc_ip`, `lib/dev-ip-lib.sh:63-66`).

## Alternatives considered
- `flock(1)` — not present on macOS by default.
- `shlock` — less portable, extra dependency.

## Consequences
`trap 'rmdir "${lock:-}" ...' RETURN` needed the `${lock:-}` / `|| true` guard to survive under `set -u` with errtrace. Lock contention only matters on first allocation of a name; repeat `alloc` calls never touch the lock.
