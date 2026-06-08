# 14. Insert dev-ip's nat-anchor in pf.conf's translation section, not append

**Status**: Accepted (2026-08-03)

## Context
`step_pf` added dev-ip's anchor to `/etc/pf.conf` by **appending**
`nat-anchor "dev-ip"` + `load anchor` to the end. But pf enforces rule-type
ordering — *options → normalization → queueing → **translation (nat/rdr)** →
filtering*. A stock macOS `pf.conf` ends with a **filter** anchor
(`anchor "com.apple/*"`), so an appended `nat-anchor` lands *after* filtering →
`pfctl -f` fails: `Rules must be in order … pf rules not loaded`. `provision`
aborted on any stock Mac with `owner=dev-ip`, leaving `pf.conf` invalid.

This was the exact "layer-3 acceptance for `owner=dev-ip` unverified" gap: the
stub suite mocks `pfctl`, and dev-ip's own pf path had never run on a real Mac
(the dev box defers pf to nix). It surfaced the first time `provision` ran
self-managed on a stock Mac.

## Decision
Insert the anchor in the **translation section**, not at the end.
`render_pf_conf_add` (pure, in `lib/`) reads `pf.conf` and inserts
`nat-anchor "dev-ip"` + `load anchor` **before the first `rdr-anchor` / filter
line** (`rdr-anchor|dummynet-anchor|anchor |block|pass`); if no such boundary
exists, it appends. This mirrors how nix-darwin inserts its own
`nat-anchor "loopback_dev"` (in the nat section, before `rdr-anchor`).
`step_pf` writes the transformed file via a temp file + `mv` (never read and
truncate `pf.conf` in one pipe). `deprovision` still strips dev-ip's lines by
content, position-independent.

## Alternatives considered
- Load the anchor at runtime only (`pfctl -a dev-ip -f file`) without touching
  `pf.conf` — the rules wouldn't be *evaluated* without a `nat-anchor` reference
  in the main ruleset, and wouldn't survive a reload. Rejected.

## Consequences
`owner=dev-ip provision` works on a stock Mac. Verified with a real-`pfctl -nf`
regression test (`test/pf-anchor.bats`) that parses `/etc/pf.conf` with dev-ip
inserted — no root needed — plus a unit test on the insertion position. Closes
one more piece of the layer-3 gap; the full hairpin *routing* behavior still
wants VM acceptance. Ships in 0.1.1.
