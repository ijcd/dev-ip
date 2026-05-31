#!/usr/bin/env bats
# The bin/dev-ip CLI shell — everyday no-sudo commands wired to the core.

setup() {
  export DEVIP_HOME="$BATS_TEST_TMPDIR/devip"
  DEVIP="${BATS_TEST_DIRNAME}/../bin/dev-ip"
}

@test "dev-ip ip NAME prints the allocated IP" {
  run "$DEVIP" ip gchs
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.10" ]
}

@test "dev-ip ip is stable across calls" {
  "$DEVIP" ip gchs
  run "$DEVIP" ip gchs
  [ "$output" = "127.0.0.10" ]
}

@test "dev-ip alloc NAME allocates and prints the IP" {
  run "$DEVIP" alloc gchs
  [ "$output" = "127.0.0.10" ]
}

@test "dev-ip free NAME releases the allocation" {
  "$DEVIP" ip gchs
  "$DEVIP" free gchs
  run "$DEVIP" ls
  [ "$output" = "" ]
}

@test "dev-ip ls lists allocations" {
  "$DEVIP" ip gchs
  run "$DEVIP" ls
  [[ "$output" == *gchs*127.0.0.10* ]]
}

@test "dev-ip ip without a name fails" {
  run "$DEVIP" ip
  [ "$status" -ne 0 ]
}

@test "dev-ip with an unknown command fails with usage" {
  run "$DEVIP" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *usage* ]]
}

@test "dev-ip with no args prints usage and fails" {
  run "$DEVIP"
  [ "$status" -ne 0 ]
  [[ "$output" == *usage* ]]
}
