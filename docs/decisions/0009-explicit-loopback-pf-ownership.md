# 9. Explicit loopback/pf ownership (default self-manage)

**Status**: Accepted (2026-08-02)

## Context
`step_classify` decided who manages loopback+pf by probing for the launchd
label `com.local.loopback-aliases`. That label is not upstream nix-darwin — it
is one user's personal config. So "auto-detect nix" was really "detect this one
user's label," coupling a standalone tool to a named consumer's setup (the same
smell ADR forbids elsewhere). It also silently deferred on hosts that didn't
actually cover the configured pool, yielding IPs that resolve but don't route.

## Decision
Delete detection (`step_classify`, `MANAGED_BY_NIX`, `_pool_aliased`, the
`com.local.loopback-aliases` and `loopback_dev` probes). Ownership is explicit:
`loopback_owner`/`pf_owner` ∈ `dev-ip | system`, **default `dev-ip`**
(`_resolve_owner` in `lib/dev-ip-lib.sh`; only the literal `system` defers).
`dev-ip` self-manages via its own distinctly-labelled daemon/anchor — additive,
so it is safe alongside an external manager; `system` defers to whatever the
user runs. dnsmasq + `/etc/resolver` are unaffected (always dev-ip's).

## Alternatives considered
- Keep auto-detection but make the label configurable — still probing, still a
  guess; explicit ownership is simpler and honest.
- Default `system` — a fresh stock-Mac install would produce non-routing IPs
  until the user found a config key. Rejected: bad first run.

## Consequences
Works out of the box on a stock Mac (default self-manage). A host that already
manages the loopback pool (nix-darwin, a hand-rolled launchd plist, anything)
sets `loopback_owner = system` / `pf_owner = system` to defer. Supersedes
ADR-0005's blanket "no dev-ip aliasing on a nix host" (it rejected this as
*automatic*; here it is the explicit, default-on behavior). Removes the personal
launchd-label coupling — dev-ip is fully standalone.
