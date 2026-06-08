# 15. Resolve dnsmasq by arch, force-restart the agent, read launchd for its state

**Status**: Accepted (2026-08-03)

## Context
Three coupled failures on a stock Apple-silicon Mac, in one chain — wrong
binary path → agent can't exec → `provision` never actually restarts it →
`doctor` misdiagnoses:

1. **Path (arch).** `_dnsmasq_bin` hardcoded keg paths and fell back to
   `/opt/homebrew/bin/dnsmasq`. On some installs it resolved/persisted
   `/usr/local/opt/dnsmasq/sbin/dnsmasq` — the **Intel** prefix, a missing
   file on arm64. The LaunchAgent then execs a path that doesn't exist.
2. **Restart.** `step_dnsmasq_agent`'s health check treated "`launchctl print`
   succeeds" as running. But bootstrapped ≠ running — a crashed or throttled
   agent still prints. So after a corrected plist was written, the dead agent
   was left in place (`runs = 0`, port 5354 unserved) until a manual
   `kickstart -k`. `load`/`bootstrap` silently no-op on a changed or throttled
   label.
3. **Diagnosis.** `doctor` inferred "crash-looping" from "port silent" and its
   remediation hardcoded the Intel path — so it mislabeled a *never-started*
   agent and prescribed a fix that re-breaks arm64.

## Decision
- **Path:** `_dnsmasq_bin` asks `brew --prefix dnsmasq` first (arch-correct:
  `/opt/homebrew` on arm64, `/usr/local` on Intel), then the known keg paths
  (arm before Intel), then `command -v dnsmasq`, then bare `dnsmasq`. Never
  hardcode a prefix in a fallback or a suggestion.
- **Restart:** health = plist current **and** `_agent_status` == running.
  On any miss, write the plist then `bootout` → `bootstrap` → **`kickstart -k`**
  — the force-restart that guarantees a fresh instance regardless of throttle
  state. `bootstrap` failures no longer abort provision (kickstart is the real
  (re)start).
- **Diagnosis:** `_agent_status` reads launchd's own fields — `stopped`
  (not bootstrapped) / `notstarted` (bootstrapped, `runs = 0`, never exited) /
  `crashloop` (ran, exited non-zero) / `running` (pid). `doctor` labels each
  distinctly, verifies `dnsmasq_bin` exists+executable and names the exact bad
  path, and its `dnsmasq_bin` suggestion uses `$(brew --prefix dnsmasq)` (shown
  literally, arch-neutral) — never `/usr/local`.

## Alternatives considered
- Keep `launchctl load` — no-ops on a changed/throttled plist; that was the
  bug. Rejected.
- Infer state from the port probe alone — can't tell never-started from
  crash-looping, which is what prescribed the harmful fix. Rejected.

## Consequences
`provision` on a stock arm64 Mac points at the real binary and the agent
actually comes up. `doctor` distinguishes never-started vs crash-looping vs
missing-binary and prescribes an arch-correct fix. Covered by launchd-state
stubs (`DEVIP_STUB_DNSMASQ_NOTSTARTED`) plus doctor/provision tests asserting
the `kickstart -k` restart and the absence of the hardcoded Intel path.
Ships in 0.1.1. Pairs with ADR-0014 (the pf half of the same stock-Mac
provisioning gap).
