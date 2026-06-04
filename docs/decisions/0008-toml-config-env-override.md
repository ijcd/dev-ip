# 8. TOML config file with env override + `config` command

**Status**: Accepted (2026-08-02)

## Context
Config was env-vars-only (`DEVIP_*`), nothing persistent. Users want a file
they can inspect and edit, without losing per-invocation env overrides.

## Decision
Add `${XDG_CONFIG_HOME:-~/.config}/dev-ip/config.toml` (override `DEVIP_CONFIG`),
a flat TOML subset. `load_config` (lib) exports each `DEVIP_<KEY>` **only if
unset**, so env wins and every existing `${DEVIP_*:-default}` read is untouched
(precedence env > file > default). One key registry — `_config_keys` emits
`key|env|default|description` lines (bash 3.2 has no assoc arrays) — drives the
loader, the `config` table, get/set validation, and the `edit` template.
Parser is ~15 lines of bash; no new dependency. `config` prints effective
values + provenance; `get`/`set` (validated, hard error on unknown key)/`edit`.

## Alternatives considered
- A TOML CLI (`yq`/`dasel`) — a new runtime dep; rejected (dep floor is perl +
  dnsmasq). The config is flat, so a bash reader suffices.
- Nested `[section]` tables — more parser complexity for no gain; keys are flat
  and map 1:1 to env vars. Deferred.

## Consequences
`loopback_owner`/`pf_owner` keys exist but are inert in phase 1 (default `auto`
= today's `step_classify`). Making them change provisioning — and superseding
ADR-0005's blanket "no dev-ip aliasing on a nix host" — is phase 2 (its own
ADR). See `docs/architecture/overview.md` for where config load sits in the
pipeline.
