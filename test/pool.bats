#!/usr/bin/env bats
# DEVIP_POOL_START/END → the pool range, via _pool_bounds (default 10 99).

setup() {
  export DEVIP_CONFIG="$BATS_TEST_TMPDIR/none.toml"   # isolate from the dev's real ~/.config
  source "${BATS_TEST_DIRNAME}/../lib/dev-ip-lib.sh"
}

@test "_pool_bounds defaults to 10 99 when env is unset" {
  run _pool_bounds
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.10 127.0.0.99" ]   # bare octets expand to full 127.0.0.x
}

@test "_pool_bounds reads DEVIP_POOL_START/END" {
  export DEVIP_POOL_START=100 DEVIP_POOL_END=199
  run _pool_bounds
  [ "$output" = "127.0.0.100 127.0.0.199" ]
}

@test "_pool_bounds accepts full 127.x IPs and spans beyond one /24" {
  export DEVIP_POOL_START=127.1.0.1 DEVIP_POOL_END=127.1.0.20
  run _pool_bounds
  [ "$status" -eq 0 ]
  [ "$output" = "127.1.0.1 127.1.0.20" ]
}

@test "_pool_bounds rejects a non-127 address" {
  export DEVIP_POOL_START=10.0.0.1 DEVIP_POOL_END=10.0.0.9
  run _pool_bounds
  [ "$status" -ne 0 ]
  [[ "$output" == *"127.x"* ]]
}

@test "_pool_bounds rejects a range larger than DEVIP_POOL_MAX" {
  export DEVIP_POOL_START=127.0.0.2 DEVIP_POOL_END=127.255.255.254
  run _pool_bounds
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds DEVIP_POOL_MAX"* ]]
}

@test "_pool_bounds rejects start > end" {
  export DEVIP_POOL_START=99 DEVIP_POOL_END=10
  run _pool_bounds
  [ "$status" -ne 0 ]
}

@test "_pool_bounds rejects non-numeric" {
  export DEVIP_POOL_START=ten DEVIP_POOL_END=99
  run _pool_bounds
  [ "$status" -ne 0 ]
}

@test "_pool_bounds rejects end > 254" {
  export DEVIP_POOL_START=10 DEVIP_POOL_END=300
  run _pool_bounds
  [ "$status" -ne 0 ]
}

@test "_pool_bounds rejects start < 2" {
  export DEVIP_POOL_START=1 DEVIP_POOL_END=99
  run _pool_bounds
  [ "$status" -ne 0 ]
}

@test "next_free_ip honors DEVIP_POOL_START" {
  export DEVIP_POOL_START=100 DEVIP_POOL_END=199
  run next_free_ip
  [ "$output" = "127.0.0.100" ]
}

@test "next_free_ip exhausts at DEVIP_POOL_END" {
  export DEVIP_POOL_START=100 DEVIP_POOL_END=101
  run next_free_ip 127.0.0.100 127.0.0.101
  [ "$status" -ne 0 ]
}

@test "alloc_ip exhaustion message reflects the configured pool range" {
  export DEVIP_HOME="$BATS_TEST_TMPDIR/devip"
  export DEVIP_POOL_START=100 DEVIP_POOL_END=101
  alloc_ip a >/dev/null    # 127.0.0.100
  alloc_ip b >/dev/null    # 127.0.0.101
  run alloc_ip c           # pool now exhausted
  [ "$status" -ne 0 ]
  [[ "$output" == *"127.0.0.100-127.0.0.101 exhausted"* ]]
}

@test "next_free_ip with used IPs returns one in-pool and not in the used set" {
  run next_free_ip 127.0.0.10 127.0.0.12
  [ "$status" -eq 0 ]
  local o="${output##*.}"
  [ "$o" -ge 10 ] && [ "$o" -le 99 ]
  [ "$output" != "127.0.0.10" ]
  [ "$output" != "127.0.0.12" ]
}
