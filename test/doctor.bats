#!/usr/bin/env bats
# doctor probe helpers — sourced directly (main is source-guarded).

setup() {
  export DEVIP_HOME="$BATS_TEST_TMPDIR/devip"
  export DEVIP_RESOLVER_DIR="$BATS_TEST_TMPDIR/resolver"
  export DEVIP_CALL_LOG="$BATS_TEST_TMPDIR/calls.log"; : > "$DEVIP_CALL_LOG"
  export PATH="${BATS_TEST_DIRNAME}/stubs:$PATH"
  source "${BATS_TEST_DIRNAME}/../bin/dev-ip"   # source-guard keeps main from running
}

@test "sourcing bin/dev-ip does not run main (no usage/output)" {
  run bash -c "source '${BATS_TEST_DIRNAME}/../bin/dev-ip'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "_probe_route honors DEVIP_STUB_ROUTE" {
  DEVIP_STUB_ROUTE=bind-fail run _probe_route 127.0.0.99
  [ "$output" = "bind-fail" ]
}

@test "_probe_route: ok for the loopback base (live perl socket)" {
  run _probe_route 127.0.0.1
  [ "$output" = "ok" ]
}

@test "_probe_route: bind-fail for a non-local address (live)" {
  run _probe_route 10.255.255.1
  [ "$output" = "bind-fail" ]
}

@test "_pf_loaded true only when pf enabled AND anchor has rules" {
  run _pf_loaded; [ "$status" -ne 0 ]
  export DEVIP_STUB_PF_ENABLED=1 DEVIP_STUB_PF_LOADED=1
  run _pf_loaded; [ "$status" -eq 0 ]
  unset DEVIP_STUB_PF_LOADED
  run _pf_loaded; [ "$status" -ne 0 ]                   # enabled but no rules
}

@test "_agent_running reflects the dnsmasq agent state" {
  run _agent_running; [ "$status" -ne 0 ]              # not running
  export DEVIP_STUB_DNSMASQ_RUNNING=1
  run _agent_running; [ "$status" -eq 0 ]              # running
}
