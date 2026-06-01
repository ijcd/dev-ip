# 7. Doctor diagnoses per component and applies owned fixes

**Status**: Accepted (2026-07-29)

## Context
`doctor` was a thin `provision --check` + one resolve probe; it couldn't say which of the routing/resolution links was broken, and never verified routing behavior.

## Decision
`doctor` probes four checks across two chains (behavior, not file-presence): a `perl` bind+connect routing probe, `dig`(:5354) and `dscacheutil` resolve probes, plus presence checks for the fix mapping. Each ✗ prints the exact fix (unified diff for owned files, command for actions). `doctor --fix` applies the dev-ip-owned fixes and reports anything it can't (nix-owned, connection issues).

## Alternatives considered
- Fold into `provision --check` — that checks file presence, not behavior; misses "loaded ≠ enabled" and "resolver file present ≠ system routes it".
- A separate `diagnose` command — "doctor" already means diagnose.
- A hairpin *behavior* probe (Docker/cross-IP) — heavier, Docker-dependent; the routing probe proves alias + native reachability, and the pf presence check covers the hairpin. Deferred.

## Consequences
`doctor` now empirically verifies alias + native reachability (never checked before) and pinpoints the broken link. It respects ADR-0003/0004: probes are owner-agnostic, `--fix` defers nix-owned loopback/pf. Adds a `dscacheutil` test stub and a `DEVIP_STUB_ROUTE` seam. The real bind+connect / `dscacheutil` run only live / in VM acceptance.
