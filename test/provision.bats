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

@test "provision --check with owner=system never mutates" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  run "$DEVIP" provision --check
  [ "$status" -eq 0 ]
  # --check writes nothing
  [ ! -d "$DEVIP_HOME/hosts.d" ]
}

@test "provision creates the hosts.d dir (step 7)" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [ -d "$DEVIP_HOME/hosts.d" ]
}

@test "provision writes the resolver file when absent (step 6)" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [ -f "$DEVIP_RESOLVER_DIR/devip" ]
  run cat "$DEVIP_RESOLVER_DIR/devip"
  [ "$output" = "nameserver 127.0.0.1
port 5354" ]
}

@test "provision rewrites nothing when the resolver already matches" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  "$DEVIP" provision              # first run writes it
  : > "$DEVIP_CALL_LOG"           # clear the log
  run "$DEVIP" provision          # second run
  [ "$status" -eq 0 ]
  run grep -c "tee" "$DEVIP_CALL_LOG"
  [ "$output" = "0" ]             # no sudo tee the second time
}

@test "provision writes the dnsmasq agent plist and reloads it (steps 4,5)" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [ -f "$DEVIP_LAUNCHAGENTS/dev-ip-dnsmasq.plist" ]
  [[ "$(cat "$DEVIP_LAUNCHAGENTS/dev-ip-dnsmasq.plist")" == *"--port=5354"* ]]
  grep -q "bootstrap" "$DEVIP_CALL_LOG"
}

@test "provision reloads the agent again only if the plist changed" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  "$DEVIP" provision
  : > "$DEVIP_CALL_LOG"
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  run grep -c "bootstrap" "$DEVIP_CALL_LOG"
  [ "$output" = "0" ]
}

@test "doctor resolves the probe end-to-end and leaves no probe behind" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
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
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system DEVIP_STUB_DNSMASQ_RUNNING=1
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
  # default owner=dev-ip -> dev-ip manages loopback+pf
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

@test "owner=system: provision skips loopback + pf" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
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
  "$DEVIP" provision              # first run installs everything
  # simulate the world now converged: agent running
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  : > "$DEVIP_CALL_LOG"
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  run grep -Ec 'write |bootstrap|append |tee |pfctl -f|mkdir' "$DEVIP_CALL_LOG"
  [ "$output" = "0" ]
}

@test "owner=system: a second provision makes zero mutations" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
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

@test "deprovision leaves a foreign loopback daemon alone" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  "$DEVIP" provision
  run "$DEVIP" deprovision
  [ "$status" -eq 0 ]
  [ ! -f "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist" ]   # dev-ip never wrote it; nothing to remove
}

@test "dev-ip ip fails fast on an invalid DEVIP_POOL range" {
  export DEVIP_POOL_START=99 DEVIP_POOL_END=10
  run "$DEVIP" ip web
  [ "$status" -ne 0 ]
  [[ "$output" == *"pool"* ]]
}

@test "provision on a stock Mac aliases the configured range" {
  export DEVIP_POOL_START=100 DEVIP_POOL_END=102
  run "$DEVIP" provision
  [ "$status" -eq 0 ]
  [[ "$(cat "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist")" == *'127.0.0.100 127.0.0.101 127.0.0.102'* ]]
}

@test "provision fails fast on an invalid DEVIP_POOL range before running any step" {
  export DEVIP_POOL_START=99 DEVIP_POOL_END=10
  run "$DEVIP" provision
  [ "$status" -ne 0 ]
  [[ "$output" == *"pool"* ]]
  [[ "$output" != *"host:"* ]]   # the pool gate returned before any step ran
}

@test "doctor warns when owner=system and the pool is not aliased" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  export DEVIP_POOL_START=100 DEVIP_POOL_END=199   # owner=system, dev-ip never aliases this range
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  export DEVIP_STUB_ROUTE=bind-fail       # probe IP (100-199) isn't aliased -> not on lo0
  "$DEVIP" provision >/dev/null 2>&1 || true
  run "$DEVIP" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"reachability"* ]]
  [[ "$output" == *"not on lo0"* ]]
}

@test "doctor shows the required resolver contents (copy-pasteable, not a diff) when missing" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system DEVIP_STUB_DNSMASQ_RUNNING=1
  # resolver absent -> system resolve fails -> fix shows the exact file contents
  run "$DEVIP" doctor
  [[ "$output" == *"$DEVIP_RESOLVER_DIR/devip"* ]]
  [[ "$output" == *"nameserver 127.0.0.1"* ]]
  [[ "$output" == *"port 5354"* ]]
  [[ "$output" != *"+nameserver"* ]]     # plain content, no diff markers
  [[ "$output" != *"@@"* ]]
  [[ "$output" == *"doctor --fix"* ]]
}

@test "doctor still shows the required contents when the resolver is present but wrong" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system DEVIP_STUB_DNSMASQ_RUNNING=1
  mkdir -p "$DEVIP_RESOLVER_DIR"
  printf 'nameserver 9.9.9.9\n' > "$DEVIP_RESOLVER_DIR/devip"   # present but wrong
  run "$DEVIP" doctor
  [[ "$output" == *"nameserver 127.0.0.1"* ]]
  [[ "$output" == *"port 5354"* ]]
}

@test "doctor --fix applies the owned fix" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system DEVIP_STUB_DNSMASQ_RUNNING=1
  run "$DEVIP" doctor --fix
  [ "$status" -eq 0 ]                     # owned-only fault, applied -> resolved
  [ -f "$DEVIP_RESOLVER_DIR/devip" ]      # step_resolver ran
  grep -q "tee" "$DEVIP_CALL_LOG"
  [[ "$output" == *"applied"* ]]
}

@test "doctor --fix leaves loopback/pf alone when owner=system" {
  export DEVIP_STUB_ROUTE=bind-fail DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system DEVIP_STUB_DNSMASQ_RUNNING=1
  run "$DEVIP" doctor --fix
  [ "$status" -ne 0 ]                     # system-owned fault left unresolved
  [ ! -f "$DEVIP_LAUNCHDAEMONS/dev-ip-loopback.plist" ]   # deferred to system
  [[ "$output" == *"system"* ]]
}

@test "doctor does not warn when the pool is aliased" {
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1 DEVIP_STUB_SYSRESOLVE_MATCHES=1
  "$DEVIP" provision >/dev/null 2>&1 || true
  run "$DEVIP" doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"not on lo0"* ]]
}

@test "doctor reads pf with sudo and counts a hairpin in any anchor (owner-agnostic)" {
  # PF_LOADED models a hairpin present in some anchor (e.g. nix's loopback_dev),
  # NOT dev-ip's own. doctor must still see it — and must elevate to read pf.
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1
  export DEVIP_PF_OWNER=system DEVIP_STUB_DNSMASQ_RUNNING=1 DEVIP_STUB_SYSRESOLVE_MATCHES=1
  run "$DEVIP" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"pf hairpin loaded"* ]]        # ✓ from a non-dev-ip anchor
  [[ "$output" != *"no loopback hairpin"* ]]      # no false ✗
  grep -q "sudo pfctl" "$DEVIP_CALL_LOG"          # it elevated to read pf
}

@test "doctor reports pf ✗ (with the fix) when no hairpin is loaded anywhere" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1   # pf on, but no hairpin rule
  export DEVIP_STUB_DNSMASQ_RUNNING=1 DEVIP_STUB_SYSRESOLVE_MATCHES=1
  run "$DEVIP" doctor
  [[ "$output" == *"no loopback hairpin"* ]]      # genuine ✗
}

@test "doctor advises owner=system when the range is already aliased but dev-ip didn't install it" {
  # route ok (aliases up), default owner=dev-ip, no dev-ip loopback daemon present
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1
  export DEVIP_STUB_DNSMASQ_RUNNING=1 DEVIP_STUB_SYSRESOLVE_MATCHES=1
  run "$DEVIP" doctor
  [[ "$output" == *"already aliased, but not by dev-ip"* ]]
  [[ "$output" == *"loopback_owner=system"* ]]
}

@test "doctor does not advise once owner=system (user already deferred)" {
  export DEVIP_STUB_ROUTE=ok DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  export DEVIP_STUB_DNSMASQ_RUNNING=1 DEVIP_STUB_SYSRESOLVE_MATCHES=1
  run "$DEVIP" doctor
  [[ "$output" != *"already aliased, but not by dev-ip"* ]]
}

@test "custom DEVIP_TLD: resolver file, verify + doctor probes, and deprovision all use it (not devip)" {
  export DEVIP_TLD=lan
  export DEVIP_LOOPBACK_OWNER=system DEVIP_PF_OWNER=system
  "$DEVIP" provision >/dev/null 2>&1 || true   # step_verify may not resolve against the
                                                # dig stub's fixed .devip parsing; only the
                                                # wiring (file + probed name) is asserted here
  [ -f "$DEVIP_RESOLVER_DIR/lan" ]
  [ ! -f "$DEVIP_RESOLVER_DIR/devip" ]
  grep -qF "probe.lan" "$DEVIP_CALL_LOG"       # step_verify probed the configured TLD

  : > "$DEVIP_CALL_LOG"
  "$DEVIP" doctor >/dev/null 2>&1 || true
  grep -qF "doctor-probe.lan" "$DEVIP_CALL_LOG"  # doctor's dnsmasq probe also uses .lan

  run "$DEVIP" deprovision
  [ "$status" -eq 0 ]
  [ ! -f "$DEVIP_RESOLVER_DIR/lan" ]
}
