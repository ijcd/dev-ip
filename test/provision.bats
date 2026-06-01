#!/usr/bin/env bats
# provision pipeline via the PATH-stub harness. No root, no VM.

setup() {
  export DEVIP_HOME="$BATS_TEST_TMPDIR/devip"
  export DEVIP_RESOLVER_DIR="$BATS_TEST_TMPDIR/resolver"
  export DEVIP_LAUNCHAGENTS="$BATS_TEST_TMPDIR/agents"
  export DEVIP_LAUNCHDAEMONS="$BATS_TEST_TMPDIR/daemons"
  export DEVIP_PF_CONF="$BATS_TEST_TMPDIR/pf.conf"
  export DEVIP_PF_ANCHOR_FILE="$BATS_TEST_TMPDIR/pf.anchors/dev-ip"
  export DEVIP_CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$DEVIP_CALL_LOG"
  export PATH="${BATS_TEST_DIRNAME}/stubs:$PATH"
  DEVIP="${BATS_TEST_DIRNAME}/../bin/dev-ip"
}

@test "provision --check classifies a nix host and never mutates" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  run "$DEVIP" provision --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"nix-managed"* ]]
  # --check writes nothing
  [ ! -d "$DEVIP_HOME/hosts.d" ]
}

@test "provision creates the hosts.d dir (step 7)" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [ -d "$DEVIP_HOME/hosts.d" ]
}

@test "provision writes the resolver file when absent (step 6)" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [ -f "$DEVIP_RESOLVER_DIR/devip" ]
  run cat "$DEVIP_RESOLVER_DIR/devip"
  [ "$output" = "nameserver 127.0.0.1
port 5354" ]
}

@test "provision rewrites nothing when the resolver already matches" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  "$DEVIP" provision              # first run writes it
  : > "$DEVIP_CALL_LOG"           # clear the log
  run "$DEVIP" provision          # second run
  [ "$status" -eq 0 ]
  run grep -c "tee" "$DEVIP_CALL_LOG"
  [ "$output" = "0" ]             # no sudo tee the second time
}

@test "provision writes the dnsmasq agent plist and reloads it (steps 4,5)" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [ -f "$DEVIP_LAUNCHAGENTS/dev-ip-dnsmasq.plist" ]
  [[ "$(cat "$DEVIP_LAUNCHAGENTS/dev-ip-dnsmasq.plist")" == *"--port=5354"* ]]
  grep -q "bootstrap" "$DEVIP_CALL_LOG"
}

@test "provision reloads the agent again only if the plist changed" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  "$DEVIP" provision
  : > "$DEVIP_CALL_LOG"
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  run grep -c "bootstrap" "$DEVIP_CALL_LOG"
  [ "$output" = "0" ]
}

@test "doctor resolves the probe end-to-end and leaves no probe behind" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1
  export DEVIP_STUB_SYSRESOLVE_MATCHES=1 DEVIP_STUB_DNSMASQ_RUNNING=1
  "$DEVIP" provision
  run "$DEVIP" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resolution:"* ]]
  [[ "$output" == *"dnsmasq"* ]]
  [ ! -f "$DEVIP_HOME/hosts.d/doctor-probe" ]     # probe cleaned up (sanitized label)
  grep -q "dig" "$DEVIP_CALL_LOG"
}

@test "doctor: routing + resolution report, all green" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_STUB_SYSRESOLVE_MATCHES=1
  export DEVIP_STUB_NIX_LOOPBACK=1 DEVIP_STUB_DNSMASQ_RUNNING=1
  "$DEVIP" provision >/dev/null 2>&1 || true
  run "$DEVIP" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Routing:"* ]]
  [[ "$output" == *"Resolution:"* ]]
  [[ "$output" == *"dnsmasq"* ]]
}

@test "doctor: a broken component makes an ✗ line and non-zero exit" {
  export DEVIP_STUB_ROUTE=bind-fail
  run "$DEVIP" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"reachability"* ]]
  [[ "$output" == *"not on lo0"* ]]
}

@test "stock Mac: provision installs loopback daemon + pf anchor (steps 2,3)" {
  # no DEVIP_STUB_NIX_LOOPBACK -> stock Mac path
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [ -f "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist" ]
  [ -f "$DEVIP_PF_ANCHOR_FILE" ]
  grep -q "dev-ip" "$DEVIP_PF_CONF"
  grep -q "pfctl" "$DEVIP_CALL_LOG"
  # anchor content is per-IP, never a subnet rule
  run grep -c "/24" "$DEVIP_PF_ANCHOR_FILE"
  [ "$output" = "0" ]
}

@test "nix host: provision skips loopback + pf (steps 2,3)" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [ ! -f "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist" ]
  [ ! -f "$DEVIP_PF_ANCHOR_FILE" ]
}

@test "pf include line is appended only once across two runs" {
  run "$DEVIP" provision
  run "$DEVIP" provision
  # the appended block is two lines (nat-anchor + load anchor), both containing
  # "dev-ip" by design -> `grep -c dev-ip` is structurally 2 even on a single
  # correct append. Count the anchor-declaration line instead: 1 == appended once.
  run grep -c 'nat-anchor "dev-ip"' "$DEVIP_PF_CONF"
  [ "$output" = "1" ]
}

@test "stock Mac: a second provision makes zero mutations" {
  export DEVIP_STUB_LOOPBACK_PRESENT=  # first run installs everything
  "$DEVIP" provision
  # simulate the world now converged: aliases present, agent running
  export DEVIP_STUB_LOOPBACK_PRESENT=1
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  : > "$DEVIP_CALL_LOG"
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  run grep -Ec 'write |bootstrap|append |tee |pfctl -f|mkdir' "$DEVIP_CALL_LOG"
  [ "$output" = "0" ]
}

@test "nix host: a second provision makes zero mutations" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  "$DEVIP" provision
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  : > "$DEVIP_CALL_LOG"
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  run grep -Ec 'write |bootstrap|append |tee |pfctl -f' "$DEVIP_CALL_LOG"
  [ "$output" = "0" ]
}

@test "deprovision removes dev-ip's resolver, agent, pf anchor, loopback daemon" {
  "$DEVIP" provision                 # stock-Mac install
  run "$DEVIP" deprovision
  [ "$status" -eq 0 ]
  [ ! -f "$DEVIP_RESOLVER_DIR/devip" ]
  [ ! -f "$DEVIP_LAUNCHAGENTS/dev-ip-dnsmasq.plist" ]
  [ ! -f "$DEVIP_PF_ANCHOR_FILE" ]
  [ ! -f "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist" ]
  run grep -c "dev-ip" "$DEVIP_PF_CONF"
  [ "$output" = "0" ]               # include line removed
}

@test "deprovision is idempotent when nothing is installed" {
  run "$DEVIP" deprovision
  [ "$status" -eq 0 ]
}

@test "deprovision leaves the nix loopback daemon alone" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  "$DEVIP" provision
  run "$DEVIP" deprovision
  [ "$status" -eq 0 ]
  [ ! -f "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist" ]   # dev-ip never wrote it; nothing to remove
}

@test "dev-ip ip fails fast on an invalid DEVIP_POOL range" {
  export DEVIP_POOL_START=99 DEVIP_POOL_END=10
  run "$DEVIP" ip web
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEVIP_POOL"* ]]
}

@test "provision on a stock Mac aliases the configured range" {
  export DEVIP_POOL_START=100 DEVIP_POOL_END=102
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [[ "$(cat "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist")" == *'seq 100 102'* ]]
}

@test "provision fails fast on an invalid DEVIP_POOL range before running any step" {
  export DEVIP_POOL_START=99 DEVIP_POOL_END=10
  run "$DEVIP" provision
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEVIP_POOL"* ]]
  [[ "$output" != *"host:"* ]]   # the main gate returned before step_classify ran
}

@test "doctor warns when a nix-managed host does not alias the configured pool" {
  export DEVIP_STUB_NIX_LOOPBACK=1        # nix-managed
  export DEVIP_STUB_LOOPBACK_PRESENT=1    # stub aliases 10-99 only
  export DEVIP_POOL_START=100 DEVIP_POOL_END=199   # not covered by the stub
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  export DEVIP_STUB_ROUTE=bind-fail       # probe IP (100-199) isn't aliased -> not on lo0
  "$DEVIP" provision >/dev/null 2>&1 || true
  run "$DEVIP" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"reachability"* ]]
  [[ "$output" == *"not on lo0"* ]]
}

@test "doctor shows a diff-style fix for a missing resolver" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_STUB_NIX_LOOPBACK=1 DEVIP_STUB_DNSMASQ_RUNNING=1
  # resolver absent -> system resolve fails -> fix shown
  run "$DEVIP" doctor
  [[ "$output" == *"$DEVIP_RESOLVER_DIR/devip"* ]]
  [[ "$output" == *"+nameserver 127.0.0.1"* ]]
  [[ "$output" == *"doctor --fix"* ]]
}

@test "doctor shows a real delta (not a full add) for a drifted resolver" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_STUB_NIX_LOOPBACK=1 DEVIP_STUB_DNSMASQ_RUNNING=1
  mkdir -p "$DEVIP_RESOLVER_DIR"
  printf 'nameserver 9.9.9.9\n' > "$DEVIP_RESOLVER_DIR/devip"   # present but wrong -> drift, not absence
  run "$DEVIP" doctor
  [[ "$output" == *"-nameserver 9.9.9.9"* ]]
  [[ "$output" == *"+nameserver 127.0.0.1"* ]]
}

@test "doctor --fix applies the owned fix" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_STUB_NIX_LOOPBACK=1 DEVIP_STUB_DNSMASQ_RUNNING=1
  run "$DEVIP" doctor --fix
  [ "$status" -eq 0 ]                     # owned-only fault, applied -> resolved
  [ -f "$DEVIP_RESOLVER_DIR/devip" ]      # step_resolver ran
  grep -q "tee" "$DEVIP_CALL_LOG"
  [[ "$output" == *"applied"* ]]
}

@test "doctor --fix leaves nix-managed loopback/pf to nix (no daemon written)" {
  export DEVIP_STUB_ROUTE=bind-fail DEVIP_STUB_NIX_LOOPBACK=1 DEVIP_STUB_DNSMASQ_RUNNING=1
  run "$DEVIP" doctor --fix
  [ "$status" -ne 0 ]                     # nix-owned fault left unresolved
  [ ! -f "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist" ]   # deferred to nix
  [[ "$output" == *"nix"* ]]
}

@test "doctor does not warn when the pool is aliased" {
  export DEVIP_STUB_NIX_LOOPBACK=1
  export DEVIP_STUB_LOOPBACK_PRESENT=1    # stub aliases 10-99
  # default pool 10-99 IS covered by the stub
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_STUB_SYSRESOLVE_MATCHES=1
  "$DEVIP" provision >/dev/null 2>&1 || true
  run "$DEVIP" doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"not on lo0"* ]]
}
