# 4. Isolated dnsmasq on 127.0.0.1:5354 / .devip, not nix's :53/.test

**Status**: Accepted (2026-07-15)

## Context
Name resolution for allocated IPs needs a resolver. The host may already run a nix-darwin dnsmasq on `:53` serving `.test`. Two dnsmasq instances can't both bind `:53`, and `.test` is that resolver's TLD to own.

## Decision
Run a dedicated user LaunchAgent dnsmasq on `127.0.0.1:5354`, `--hostsdir=hosts.d` (changed to `--addn-hosts` in ADR-0012 — `--hostsdir` is unsupported on macOS), `--no-hosts --no-resolv` (`render_dnsmasq_plist`; `step_dnsmasq_agent`). Default TLD `.devip`, configurable to a single alternate TLD via `DEVIP_TLD` — it writes `/etc/resolver/<tld>` (`render_resolver`; `step_resolver`) routed to the same `:5354` daemon, which answers any `hosts.d` name regardless of suffix. Multi-TLD (serving several TLDs at once from one daemon) is deferred — not built; only one `DEVIP_TLD` is supported at a time.

## Alternatives considered
- Reuse nix's dnsmasq on `:53`/`.test` — port conflict (`:53` in use), and nix already owns `.test` (idle or not, not dev-ip's to repurpose).
- Default to `.test` because it is **RFC 6761 reserved** (guaranteed never a
  public TLD) — the "safe" choice on paper. Rejected as the *default*: `.test`
  is *the* conventional local-dev TLD (nix-darwin, Laravel Valet, every dnsmasq
  tutorial), which makes it the TLD most likely to be **already claimed** on a
  real host — it is on ours (`/etc/resolver/test` → nix). `.devip` is unreserved
  (a small, theoretical risk of a future ICANN delegation) but trades that for
  avoiding the far more likely *local* collision — the coexistence this ADR is
  about. A clean host that prefers the reserved TLD can opt in via
  `dev-ip config set tld test`.

## Consequences
dev-ip coexists with any system, never clobbers it. One configured TLD = one resolver file, one daemon. `/etc/resolver/<tld>` (step 5, post-ADR-0009) is the sole always-sudo step when `loopback_owner = system` and `pf_owner = system` — the loopback/pf steps (ADR-0003) skip then. See `docs/architecture/overview.md` for the data-flow diagram and ADR-0009 for the ownership model.
