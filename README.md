# dev-ip

Static per-workspace loopback IP + hostname allocator for macOS. Give each project/branch its own `127.0.0.x` and a `name.devip` hostname, so multiple isolated dev instances run at once on one machine — no `/etc/hosts` edits, no mDNS, no sudoers.

```sh
$ dev-ip ip my-feature
127.0.0.11
$ curl http://my-feature.devip:8080/     # after binding a server to 127.0.0.11
```

## How it works

```
  dev-ip ip <name>  ─▶  ~/.local/share/dev-ip/hosts.d/<name>   ("127.0.0.11 my-feature.devip")
                              │ (dnsmasq --hostsdir auto-reload)
                         dnsmasq  (user LaunchAgent, 127.0.0.1:5354)
                              ▲ routed by
                         /etc/resolver/devip   (nameserver 127.0.0.1, port 5354)
```

- **`hosts.d/<name>`** is the single source of truth — both the allocation registry and what dnsmasq serves. `alloc` scans it for used IPs; `free` is `rm`.
- A dedicated **user dnsmasq on `127.0.0.1:5354`** answers the `.devip` TLD, routed there by `/etc/resolver/devip`. It never touches `:53`.
- On macOS, loopback aliases only route with a **per-IP PF hairpin NAT** rule, so `provision` installs those on a stock Mac.

Full detail: [`docs/architecture/overview.md`](docs/architecture/overview.md); design rationale in [`docs/decisions/`](docs/decisions/).

## Requirements

- macOS (uses `ifconfig lo0 alias`, `pfctl`, `/etc/resolver`, `launchd` — macOS/BSD-specific).
- `perl` — base macOS; used only for the allocation lock (`flock`).
- `dnsmasq` — `brew install dnsmasq`.
- `bats-core` to run the tests — `brew install bats-core`.

## Install

```sh
git clone https://github.com/ijcd/dev-ip ~/src/dev-ip
ln -s ~/src/dev-ip/bin/dev-ip /usr/local/bin/dev-ip   # or add bin/ to PATH
```

## Usage

```sh
dev-ip ip <name>      # allocate (if needed) and print the loopback IP for <name>
dev-ip alloc <name>   # alias for `ip`
dev-ip free <name>    # release <name>'s allocation
dev-ip ls             # list allocations
dev-ip provision      # converge host: resolver + dnsmasq (+ loopback/pf on a stock Mac)
dev-ip doctor         # diagnose routing/resolution status per component + show exact fixes
dev-ip doctor --fix   # apply the fixes dev-ip owns (defers nix-owned loopback/pf)
dev-ip deprovision    # remove dev-ip's host changes
```

`ip`/`alloc`/`free`/`ls` need no sudo. `provision` needs sudo only for the steps that write to `/etc` (`/etc/resolver/devip`, and loopback/pf on a stock Mac).

A consumer binds its services to the allocated IP:

```sh
LB_IP=$(dev-ip ip my-feature)
docker compose -p my-feature up -d          # compose reads ${LB_IP:-127.0.0.1}
# or: mix phx.server --ip "$LB_IP"
```

### Diagnosing routing and resolution

`doctor` probes six components (routing chain + resolution chain) and reports per-component status: alias presence and reachability on loopback, resolver file, dnsmasq agent, and resolution. For each failed check, `doctor` shows the exact fix — a unified diff for owned files, a command for actions. `doctor --fix` applies the dev-ip-owned fixes (skipping nix-managed loopback/PF). See ADR-0007.

## Configuration

All via environment variables:

| Var | Default | Purpose |
|---|---|---|
| `DEVIP_POOL_START` / `DEVIP_POOL_END` | `10` / `99` | IP pool range (last octet in `127.0.0.x`, `2`–`254`). Set a non-overlapping range to coexist with another allocator. |
| `DEVIP_TLD` | `devip` | the TLD served (`--tld` on `provision` for multiple). |
| `DEVIP_HOME` | `~/.local/share/dev-ip` | registry location. |

Provisioning paths (`DEVIP_RESOLVER_DIR`, `DEVIP_LAUNCHAGENTS`, `DEVIP_LAUNCHDAEMONS`, `DEVIP_PF_CONF`, `DEVIP_PF_ANCHOR_FILE`) are also overridable — the test suite redirects them to a temp dir.

## Coexisting with a system that already manages loopback/PF

If a nix-darwin (or similar) setup already aliases the loopback pool and manages PF, `dev-ip provision` detects it and **skips** the loopback + PF steps, deferring to that system — it only writes `/etc/resolver/devip` and its own dnsmasq agent. If you point `DEVIP_POOL_START/END` at a range that system does *not* alias, `doctor` warns that those IPs will resolve but not route.

## Testing

```sh
bats test/            # ~72 tests; no root, no VM
bats test/render.bats # one file
```

The host-provisioning logic is testable without root or a VM via two seams: every path is a `DEVIP_*` env var (redirected to a temp dir), and every external command (`ifconfig`/`pfctl`/`launchctl`/`dig`/`sudo`) is a stub on `$PATH` that logs its argv. The core assertion is that a second `provision` run makes zero mutations.

## Known limitations

- **Layer-3 acceptance is unverified in CI** — that the PF hairpin actually routes a bound service on a real Mac is checked by [`test/acceptance/vm-provision.sh`](test/acceptance/), which must run on a real Apple-silicon macOS VM (the stub suite can't cover it).

## License

GPL-3.0 — see [LICENSE](LICENSE). Copyright © 2026 Ian Duggan.
