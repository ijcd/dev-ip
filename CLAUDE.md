# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`dev-ip` — a bash CLI that allocates one loopback IP + hostname per workspace/branch, statically, so multiple isolated dev instances run at once on one machine. Names resolve via a dedicated user `dnsmasq` on `127.0.0.1:5354`, routed by `/etc/resolver/<tld>` (default TLD `.devip`). No mDNS, no `/etc/hosts` edits, no sudoers. macOS/BSD-specific.

## Source of truth — read these first

- **`docs/dev-ip-plan.md`** — the full spec: architecture, the 8 `provision` steps, macOS `pf` requirement, idempotency rules, test plan. Authoritative.
- **`HANDOFF.md`** — "where we stopped" layer over the plan: what's done, gotchas, env facts, the one unverified item (layer-3 VM acceptance). Keep it current.

`ijcd/host-provisioning` merged to `main` — commit only when the author asks — never self-commit.

## Commands

```sh
bats test/                 # run all tests (53 tests; bats-core 1.13.0; brew install bats-core)
bats test/registry.bats    # run one file
bin/dev-ip ip <name>       # allocate + print loopback IP (works now, no sudo)
bin/dev-ip ls              # list allocations
bin/dev-ip provision       # converge host resolver/loopback/pf/dnsmasq (sudo: resolver step)
bin/dev-ip doctor          # provision --check + end-to-end resolve probe
bin/dev-ip deprovision     # remove dev-ip's host changes
```

`provision` / `doctor` / `deprovision` are fully implemented (`bin/dev-ip:161-200`): `do_provision` runs 8 detect-then-mutate `step_*` functions (`bin/dev-ip:32-159`), `do_doctor` = `provision --check` + the resolve probe, `do_deprovision` reverses only dev-ip's own host changes. Not yet verified: layer-3 acceptance on a real macOS VM — see `HANDOFF.md`.

## Architecture — functional core / imperative shell

This split is the point of the project; preserve it.

- **`lib/dev-ip-lib.sh`** — pure functional core. No IO, no side effects (except the one registry write in `alloc_ip`/`free_name`). Content renderers (`render_resolver`, `render_dnsmasq_plist`, `render_pf_anchor`, `render_loopback_plist`) return strings; the allocator (`next_free_ip`, `alloc_ip`) is deterministic. Sourced by both the CLI and the tests.
- **`bin/dev-ip`** — imperative shell. `set -euo pipefail`, sources the lib, `case`-dispatches commands, performs all host IO. Composes core functions; does not reimplement them.

## Test seams — the discipline that makes the host layer testable without root/VM

Two injectable seams let macOS-specific provisioning logic be tested anywhere:

1. **Filesystem = path indirection, not mocking.** Every path dev-ip writes is a `DEVIP_*` env var with a real default (`DEVIP_HOME`, `DEVIP_RESOLVER_DIR`, `DEVIP_PF_CONF`, `DEVIP_PF_ANCHOR_FILE`, `DEVIP_LAUNCHAGENTS`, `DEVIP_LAUNCHDAEMONS` — `bin/dev-ip:10-15`). Tests point them at `$BATS_TEST_TMPDIR` and `cmp`/`cat` the real bytes — which also verifies the plan's "deterministic content" rule.
2. **Commands = `$PATH` stubs.** Put fake `ifconfig`/`pfctl`/`launchctl`/`dig`/`dnsmasq`/`sudo` in `test/stubs/` first on `$PATH`; each prints canned output (to drive a detected-state branch) and appends its argv to `$DEVIP_CALL_LOG`. Assert *decisions* and idempotency — the core assertion is **a 2nd `provision` run logs zero mutation calls**.

**Do NOT test the host layer in a Linux container.** dev-ip uses `ifconfig lo0 alias`, `pfctl` NAT anchors, `/etc/resolver`, launchd — a container exercises none of it. Layer-3 acceptance runs on a Tart macOS VM (Apple silicon).

## Conventions

- New pure logic (renderers, allocation) → `lib/`, written test-first, one `.bats` file per concern (`sanitize`, `alloc`, `registry`, `render`, `cli`).
- Registry files are dnsmasq-format: one line `IP label.tld`, filename = sanitized DNS label.
- Idempotent everywhere: detect-before-mutate; write only on content diff (`cmp -s`); missing-target removals are no-ops.
- Names become DNS labels via `sanitize_name` (slugify: runs of non-`[a-z0-9]` → single `-`). Note: this diverges from the plan's literal wording — see the naming gotcha in `HANDOFF.md`.
