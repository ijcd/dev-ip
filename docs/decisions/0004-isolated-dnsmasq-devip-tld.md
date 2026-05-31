# 4. Isolated dnsmasq on 127.0.0.1:5354 / .devip, not nix's :53/.test

**Status**: Accepted (2026-07-15)

## Context
Name resolution for allocated IPs needs a resolver. The host may already run a nix-darwin dnsmasq on `:53` serving `.test`. Two dnsmasq instances can't both bind `:53`, and `.test` is that resolver's TLD to own.

## Decision
Run a dedicated user LaunchAgent dnsmasq on `127.0.0.1:5354`, `--hostsdir=hosts.d`, `--no-hosts --no-resolv` (`render_dnsmasq_plist`, `lib/dev-ip-lib.sh:106-130`; `step_dnsmasq_agent`, `bin/dev-ip:101-123`). Default TLD `.devip`, `--tld` configurable, multiple allowed — each writes its own `/etc/resolver/<tld>` (`render_resolver`, `lib/dev-ip-lib.sh:100-102`; `step_resolver`, `bin/dev-ip:134-147`) routed to the same `:5354` daemon, which answers any `hosts.d` name regardless of suffix.

## Alternatives considered
- Reuse nix's dnsmasq on `:53`/`.test` — port conflict (`:53` in use), and nix already owns `.test` (idle or not, not dev-ip's to repurpose).

## Consequences
dev-ip coexists with nix, never clobbers it. N configured TLDs = N resolver files, one daemon. `/etc/resolver/devip` (step 6) is the sole always-sudo step on a nix host — the loopback/pf steps (ADR-0003) are skipped there. See `docs/architecture/overview.md` for the data-flow diagram.
