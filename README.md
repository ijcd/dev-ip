# dev-ip

Static per-workspace loopback IP + hostname allocator for macOS. Give each
project or branch its own `127.0.0.x` and a `name.devip` hostname, so several
isolated dev instances run at once on one machine — no `/etc/hosts` edits, no
mDNS, and no `/etc/sudoers` rule (allocation needs no sudo; only the one-time
`provision` prompts for it).

```sh
$ dev-ip ip my-feature
127.0.0.11
$ curl http://my-feature.devip:8080/     # after binding a server to 127.0.0.11
```

Allocation is an instant, no-sudo file write. Names resolve through a dedicated
user `dnsmasq` on `127.0.0.1:5354`, routed by `/etc/resolver/devip`. macOS/BSD
only.

## Getting started

### Requirements

- **macOS** — uses `ifconfig lo0 alias`, `pfctl`, `/etc/resolver`, `launchd`.
- **dnsmasq** — `brew install dnsmasq` (also pulled in as a Homebrew dependency).
- **perl** — ships with macOS; used only for the allocation lock and doctor's
  reachability probe.

### Install

```sh
brew install ijcd/tap/dev-ip
```

Or from source:

```sh
git clone https://github.com/ijcd/dev-ip ~/src/dev-ip
ln -s ~/src/dev-ip/bin/dev-ip /usr/local/bin/dev-ip   # or add bin/ to PATH
```

### First run

```sh
dev-ip ip my-feature          # → 127.0.0.11   (instant, no sudo)
dev-ip provision              # one-time host setup; sudo only for /etc/resolver
dev-ip doctor                 # per-component health report + exact fixes
curl http://my-feature.devip:8080/   # once a server is bound to 127.0.0.11
```

`ip`/`ls`/`free` never need sudo. `provision` needs sudo only to write
`/etc/resolver/devip` (and the loopback/PF steps on a stock Mac). If something
looks off, `dev-ip doctor` tells you what's wrong and `dev-ip doctor --fix`
applies the parts dev-ip owns.

## How it works

```
  dev-ip ip <name>  ─▶  ~/.local/share/dev-ip/hosts.d/<name>   ("127.0.0.11 my-feature.devip")
                              │ (dnsmasq --addn-hosts; SIGHUP on alloc)
                         dnsmasq  (user LaunchAgent, 127.0.0.1:5354)
                              ▲ routed by
                         /etc/resolver/devip   (nameserver 127.0.0.1, port 5354)
```

- **`hosts.d/<name>`** is the single source of truth — both the allocation
  registry and what dnsmasq serves. `alloc` scans it for used IPs; `free` is `rm`.
- A dedicated **user dnsmasq on `127.0.0.1:5354`** answers the `.devip` TLD,
  routed there by `/etc/resolver/devip`. It never touches `:53`. dnsmasq reads
  `hosts.d` via `--addn-hosts` and is `SIGHUP`ed on each allocation to pick up
  new names (macOS lacks the `--hostsdir` auto-watch).
- On macOS, loopback aliases only route with a **per-IP PF hairpin NAT** rule,
  so `provision` installs those when dev-ip owns the routing layer.

Full detail: [`docs/architecture/overview.md`](docs/architecture/overview.md);
design rationale in [`docs/decisions/`](docs/decisions/).

## Usage

```sh
dev-ip ip <name>      # allocate (if needed) and print the loopback IP for <name>
dev-ip alloc <name>   # alias for `ip`
dev-ip free <name>    # release <name>'s allocation
dev-ip ls             # list allocations
dev-ip provision      # converge host: resolver + dnsmasq (+ loopback/pf if owned)
dev-ip doctor         # diagnose routing/resolution per component + show fixes
dev-ip doctor --fix   # apply the fixes dev-ip owns (sudo for /etc/resolver)
dev-ip deprovision    # remove dev-ip's host changes
dev-ip config         # show / get / set / edit configuration
```

A consumer binds its services to the allocated IP:

```sh
LB_IP=$(dev-ip ip my-feature)
docker compose -p my-feature up -d          # compose reads ${LB_IP:-127.0.0.1}
# or: mix phx.server --ip "$LB_IP"
```

## Configuration

Config resolves **env var > `config.toml` > default**. The file lives at
`${XDG_CONFIG_HOME:-~/.config}/dev-ip/config.toml` (override `DEVIP_CONFIG`).

```sh
dev-ip config                 # effective values + where each came from
dev-ip config get tld
dev-ip config set pool_start 100
dev-ip config edit            # opens $EDITOR, seeded with a commented template
```

TOML keys map to env vars by name (`pool_start` ↔ `DEVIP_POOL_START`); dev-ip
reads a flat subset of TOML (top-level `key = value`, `#` comments).

| Var | Default | Purpose |
|---|---|---|
| `DEVIP_LOOPBACK_OWNER` | `dev-ip` | who manages loopback aliases (`dev-ip` self-manages; `system` defers to an external manager). |
| `DEVIP_PF_OWNER` | `dev-ip` | who manages PF hairpin NAT (`dev-ip` / `system`). |
| `DEVIP_POOL_START` / `DEVIP_POOL_END` | `10` / `99` | pool range. Each bound is a bare octet (`= 127.0.0.N`) **or** a full `127.x.x.x` address — the pool can sit anywhere in `127.0.0.0/8`. |
| `DEVIP_POOL_MAX` | `65536` | max pool size in IPs (caps the per-IP PF/alias cost). |
| `DEVIP_TLD` | `devip` | the TLD served, routed via `/etc/resolver/<tld>`. |
| `DEVIP_HOME` | `~/.local/share/dev-ip` | registry location. |
| `DEVIP_DNSMASQ_BIN` | *(auto)* | dnsmasq binary; blank = prefer the Homebrew build, else PATH. |

## Coexisting with nix or another loopback/PF manager

By default dev-ip self-manages loopback aliases and PF. If a system (nix-darwin,
a hand-rolled launchd plist, anything) already owns the loopback pool and PF,
set `loopback_owner = system` and `pf_owner = system` — dev-ip then skips those
steps and only manages `/etc/resolver/devip` and its own dnsmasq agent. `doctor`
notices when a range is already aliased by something else and suggests deferring.

## Contributing

### Architecture — functional core / imperative shell

- **`lib/dev-ip-lib.sh`** — the pure core: deterministic renderers, allocation
  and pool math, and the one registry IO adapter (`hosts.d` + a kernel flock).
  No host mutation. Sourced by both the CLI and the tests.
- **`bin/dev-ip`** — the imperative shell: `set -euo pipefail`, sources the lib,
  dispatches commands, performs all host IO. It composes core functions; it does
  not reimplement them.

Keep this split. New pure logic goes in `lib/`, written test-first.

### Running the tests

```sh
brew install bats-core
bats test/            # the full suite; no root, no VM
bats test/render.bats # one file
```

The host layer is testable without root or a VM via two seams:

1. **Filesystem = path indirection.** Every path dev-ip writes is a `DEVIP_*`
   env var; tests point them at a temp dir and compare the real bytes.
2. **Commands = `$PATH` stubs.** Fake `ifconfig`/`pfctl`/`launchctl`/`dig`/
   `sudo` in `test/stubs/` log their argv to `$DEVIP_CALL_LOG`; tests assert
   *decisions* and idempotency — the core assertion is that a second `provision`
   run makes **zero mutations**.

Stubs can't catch real-daemon behavior, so **`test/integration.bats`** runs an
actual dnsmasq with dev-ip's flags on `:5355` and asserts a name resolves (it
skips when no dnsmasq is installed). That test exists because the stubbed suite
once hid a real bug — see the gotcha below.

### Conventions

- **macOS-only host layer.** Do **not** test provisioning in a Linux container —
  it exercises none of `ifconfig lo0 alias`, `pfctl` anchors, `/etc/resolver`, or
  launchd. Real host behavior is covered by the integration test and, for the
  full routing path, a Tart macOS VM.
- **Idempotent everywhere:** detect-before-mutate; write only on a content diff;
  missing-target removals are no-ops.
- **Decisions are recorded.** Non-trivial changes get an ADR in
  `docs/decisions/NNNN-*.md`; current-state diagrams live in
  `docs/architecture/`. Read the ADRs before changing a mechanism.
- **Gotcha, learned the hard way:** dnsmasq uses `--addn-hosts` (+ SIGHUP), not
  `--hostsdir` — the latter is Linux-inotify-only and silently crash-loops on
  macOS (ADR-0012). Anything that touches a real external tool needs an
  integration test, not just a stub.

### Submitting changes

Branch, keep the core/shell split, add tests (unit + integration where a real
tool is involved), run `bats test/`, and note any ADRs your change adds. Open a
PR against `main`.

## Known limitations

- **Layer-3 acceptance for `owner=dev-ip` is unverified in CI** — that dev-ip's
  own loopback daemon + PF hairpin actually route a bound service on a stock Mac
  is checked by [`test/acceptance/vm-provision.sh`](test/acceptance/), which must
  run on a real Apple-silicon macOS VM (the stub suite can't cover it).

## License

[GPL-3.0](LICENSE) — Copyright © 2026 Ian Duggan.
