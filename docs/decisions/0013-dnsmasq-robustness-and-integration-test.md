# 13. dnsmasq binary selection, crash-loop detection, real integration test

**Status**: Accepted (2026-08-03)

## Context
ADR-0012 fixed the `--hostsdir` bug, but the *class* of bug was unprotected:
dev-ip ran whatever `command -v dnsmasq` returned (it picked builds that
rejected our flags), doctor called a crash-looping agent "loaded" (launchd
`_agent_running` was true while the process kept exiting), and no test ran a
real dnsmasq — so the whole resolution path was invisible to CI.

## Decision
Three reinforcing protections:

1. **Binary selection (`_dnsmasq_bin`, `dnsmasq_bin` config key).** Order:
   `dnsmasq_bin` config/env if set → else the Homebrew build the formula
   `depends_on` (`…/opt/dnsmasq/sbin/dnsmasq`, the one we can vouch for) →
   else `command -v dnsmasq`. `step_dnsmasq_bin` fails loud if the chosen
   binary is missing rather than writing a dead path into the plist.
2. **doctor crash-loop detection (`_agent_status`).** Reads launchd `state` +
   `last exit code` and distinguishes `stopped` / `crashloop` / `running`.
   A crash-loop reports "loaded but keeps exiting — usually a dnsmasq build that
   rejects a flag" and points at `dnsmasq_bin`, instead of the old vague
   "running but no answer". "Loaded" is no longer mistaken for "working".
3. **Real integration test (`test/integration.bats`).** Starts an actual
   dnsmasq with dev-ip's exact resolution flags on `:5355` + a temp `hosts.d`,
   asserts a name resolves and a SIGHUP picks up a new one. Skips when no
   dnsmasq is installed; needs no root or VM. This is the test that would have
   caught `--hostsdir` on day one.

## Alternatives considered
- A `--test` capability probe at provision — rejected: dnsmasq's `--test`
  accepts unsupported flags (`--hostsdir` passes `--test`, fails at startup), so
  it cannot detect the problem. The runtime crash-loop check + integration test
  cover it instead.

## Consequences
Config keys grow to 13 (`dnsmasq_bin`). The suite now includes a real-daemon
test (still "no root, no VM"; skipped without dnsmasq). Binary paths are a
config option per the same pattern (use if set, else auto). Reinforces ADR-0012.
