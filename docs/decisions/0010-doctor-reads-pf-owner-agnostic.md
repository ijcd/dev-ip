# 10. doctor reads pf with sudo, checks the hairpin owner-agnostically

**Status**: Accepted (2026-08-03)

## Context
`doctor`'s pf-hairpin check had two bugs. (1) `pfctl` reads need root, but
`doctor` runs unprivileged — so `_pf_loaded` always got `Permission denied` and
reported a false ✗ on every normal run, regardless of what was loaded. (2) It
looked only at dev-ip's own `dev-ip` pf anchor, so a hairpin provided by another
manager (nix's `loopback_dev`, a hand-rolled anchor) read as "not loaded" — and
`doctor` then offered to install a redundant 90-line anchor. `pfctl -a '*' -s nat`
does not recurse anchors on macOS, so a naive "check all anchors" fails too.

## Decision
`_pf_loaded` (`bin/dev-ip`) now: elevates the reads (`sudo pfctl`); prints a
heads-up first (`sudo -n true` probe → "reading the pf ruleset needs root — sudo
will prompt") so a read-only command never silently prompts; and finds the
hairpin **owner-agnostically** by enumerating anchors (`pfctl -s Anchors`, then
`pfctl -a <name> -s nat` per anchor) and matching `nat on lo0 … -> 127.0.0.1` in
any of them. Owner still drives only the *remediation* text when a hairpin is
genuinely absent (`_fix_pf`): `dev-ip` offers its anchor, `system` defers.

## Alternatives considered
- `pfctl -a '*' -s nat` — assumed to recurse; it does not on macOS (verified
  against a live nix `loopback_dev` anchor). Enumerate instead.
- Neutral "not checked (needs sudo)" and never elevate — honest, but the user
  asked doctor to actually check; elevating with a heads-up does that.
- Behavior probe (send a real cross-IP packet) — heavier, Docker-dependent;
  deferred (as in ADR-0007).

## Consequences
`doctor` tells the truth about routing even when an external manager owns pf
(reachability ✓ + pf ✓), and never proposes a duplicate install. Cost: it
elevates (one sudo prompt, cached after) and makes one `pfctl` call per anchor.
Reads only — `doctor` still mutates nothing. Extends ADR-0007/0009.
