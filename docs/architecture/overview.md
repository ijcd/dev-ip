# dev-ip — architecture overview

Mutable — edit as the system changes. Rationale for the decisions below lives in `docs/decisions/`.

## Data flow

```
  workspace ─ dev-ip ip <name> ─▶ ~/.local/share/dev-ip/hosts.d/<name>  ("127.0.0.11 gchs.devip")
                                        │ (auto-reload)
                                   dnsmasq  (user LaunchAgent, 127.0.0.1:5354, --hostsdir)
                                        ▲ routed by
                                   /etc/resolver/devip  ("nameserver 127.0.0.1" + "port 5354")
  bind anything to the IP:  docker  LB_IP=127.0.0.11 compose up   → http://gchs.devip:8080
                            native  mix phx.server --ip 127.0.0.11 → http://gchs.devip:4000
  IPs only work on macOS because of:  loopback aliases + per-IP PF hairpin NAT (below)
```

`hosts.d/<name>` is the single source of truth — registry and what dnsmasq serves. `alloc` scans it for used IPs; `free` is `rm`. See ADR-0004 for why dnsmasq runs on `127.0.0.1:5354`/`.devip` instead of nix's `:53`/`.test`.

Loopback aliases are dead on macOS without a per-IP PF hairpin NAT rule:

```
nat on lo0 from 127.0.0.11 to 127.0.0.11 -> 127.0.0.1    # ONE rule per alias IP — NOT a /24
```

Per-IP, never `/24` (a subnet rule breaks cross-IP traffic). Loaded as a pf anchor into `/etc/pf.conf`, then `pfctl -f` + `pfctl -e`. Boot-race guard: `pfctl -f` can run before `/etc/static` activation, so provisioning must retry and verify the anchor populated (`pfctl -a <anchor> -s nat | grep '^nat'`). See ADR-0003 for the loopback-alias mechanism these NAT rules depend on.

## Functional core / imperative shell

`lib/dev-ip-lib.sh` is pure renderers + allocation logic + a registry adapter, not a pure core end to end: `sanitize_name`, `next_free_ip`, and the `render_*` functions (plist/resolver/pf-anchor content) are pure, no IO. `used_ips`, `alloc_ip`/`_alloc_new`, `free_name`, and `list_allocations` are the registry adapter — they read/write the `hosts.d` files, and `_with_lock` does the one IO the CLI delegates to the lib (`exec`-ing a perl `flock`, see ADR-0006). The lib owns this because the registry is the one piece of persistence state pure allocation logic can't be computed without touching.

`bin/dev-ip` is the imperative shell — sources the lib, calls `load_config` to populate `DEVIP_*` from `config.toml` where env is unset (see ADR-0008), adds host-layer seams (`DEVIP_RESOLVER_DIR`, `DEVIP_LAUNCHAGENTS`, `DEVIP_LAUNCHDAEMONS`, `DEVIP_PF_CONF`, `DEVIP_PF_ANCHOR_FILE`, overridable in tests), and performs all mutation: `launchctl`, `pfctl`, `sudo tee`, file writes gated by detect-then-mutate checks.

## Provision pipeline (8 steps)

`dev-ip provision` runs each step as detect-then-maybe-mutate; `--check` prints intent and mutates nothing; `doctor` = `--check` + a live resolve probe.

| # | Step | Detect (skip if true) | Mutate | Sudo |
|---|------|------------------------|--------|------|
| 1 | classify host | — | set `MANAGED_BY_NIX=1` if `launchctl print system/com.local.loopback-aliases` exists | no |
| 2 | loopback aliases | nix-managed, or all pool IPs already on `lo0` | install `/Library/LaunchDaemons/dev-ip-loopback.plist` (ADR-0003) | yes |
| 3 | PF hairpin | nix anchor present (`pfctl -a loopback_dev -s nat`) | write `/etc/pf.anchors/dev-ip`, append `/etc/pf.conf` include if absent, `pfctl -f` + `-e` | yes |
| 4 | dnsmasq binary | `command -v dnsmasq` | report + instruct; no auto-install without `--yes` | no |
| 5 | dnsmasq agent | plist current and `launchctl print gui/$UID/dev-ip-dnsmasq` running | write `dev-ip-dnsmasq.plist`, bootout+bootstrap (ADR-0004) | no |
| 6 | resolver | `/etc/resolver/devip` byte-equal to desired | write it (ADR-0004) | yes |
| 7 | hosts.d | dir exists | `mkdir -p` | no |
| 8 | verify | — | write probe, `dig` it, `rm` — fail loudly on mismatch | no |

Steps 2-3 are the only sudo on a stock Mac; a nix-managed host skips them (detected in step 1), leaving step 6 (`/etc/resolver/devip`) as the sole sudo. `dev-ip deprovision` reverses only what dev-ip installed — never nix's resources.

## Diagnostics

`doctor` probes four checks empirically — not file-presence, but behavior. Grouped into two chains:

**Routing:** loopback **reachability** (native bind+connect probe — proves alias + native reachability, not the hairpin), **pf hairpin loaded** (presence check; required for Docker/cross-IP).
**Resolution:** dnsmasq **(:5354) answering** (dig probe; failure text distinguishes "agent not running" from "running but no answer"), **system resolver routes .devip** (dscacheutil probe — catches cases where dig passes but system DNS fails).

Each ✗ shows the exact fix (unified diff for owned files — resolver, pf anchor, loopback daemon — or command for actions). `doctor --fix` applies the dev-ip-owned fixes and reports anything it can't (nix-owned, connection issues). See ADR-0007.

## Cross-references

- ADR-0001 — name sanitization (`sanitize_name`).
- ADR-0002 — mkdir-lock for concurrent `alloc`.
- ADR-0003 — root LaunchDaemon for loopback aliases (steps 1-2 above).
- ADR-0004 — isolated dnsmasq / TLD choice (steps 4-6 above, and the data-flow diagram at the top of this doc).
- ADR-0005 — configurable pool range (default `127.0.0.10-99`, see `DEVIP_POOL_START`/`DEVIP_POOL_END`).
- ADR-0006 — kernel advisory lock via `perl` `flock` for concurrent `alloc` (supersedes ADR-0002).
- ADR-0007 — `doctor` diagnoses per-component routing/resolution status and applies owned fixes.
- ADR-0008 — TOML config file with env override + `config` command.
