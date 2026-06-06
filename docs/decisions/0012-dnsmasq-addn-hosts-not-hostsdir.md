# 12. dnsmasq via --addn-hosts + SIGHUP, not --hostsdir (unsupported on macOS)

**Status**: Accepted (2026-08-03)

## Context
The resolver ran dnsmasq with `--hostsdir=<hosts.d>` (ADR-0004) for automatic
reload when allocations change. But `--hostsdir` is a compile-time feature tied
to Linux inotify — **both** the nix (2.93) and Homebrew dnsmasq builds reject it
on macOS: `dhcp-hostsdir, dhcp-optsdir and hostsdir are not supported on this
platform`, exit 1. So the LaunchAgent crash-looped (KeepAlive), never bound
`:5354`, and no name ever resolved. The stub suite mocks dnsmasq and the
layer-3 acceptance (real dnsmasq) was never run, so dev-ip's core resolution
had in fact never worked on macOS — discovered only on a live box.

## Decision
Run dnsmasq with `--addn-hosts=<hosts.d>` — a directory of hosts-format files,
which is exactly what the registry already writes, and which IS supported on
macOS. `--addn-hosts` reloads only on SIGHUP (no directory auto-watch), so
`dev-ip ip` / `free` and the doctor/verify probes send the agent a SIGHUP
(`_reload_dnsmasq` in `bin/dev-ip`) after touching `hosts.d`. No sudo — it
signals the user's own agent; a no-op if the agent is not running.

## Alternatives considered
- Keep `--hostsdir`, require a dnsmasq built with it — no such macOS build
  exists via nix or brew. Rejected.
- Single `--addn-hosts=<file>` rewritten per alloc — loses the
  one-file-per-name registry. The directory form keeps it (ADR-0004).

## Consequences
DNS resolution works on macOS now — verified live: existing names resolve and a
fresh allocation appears after SIGHUP. Allocation stays a no-sudo file write
plus a best-effort SIGHUP. Supersedes ADR-0004's `--hostsdir` mechanism (its
`:5354` / `.devip` / isolation-from-nix decisions stand). Fixing this also
closed a test-isolation hole: every bats `setup()` now pins `DEVIP_CONFIG` so
the suite never reads the developer's real `~/.config/dev-ip/config.toml`
(which had masked itself until a dev box actually had one).
