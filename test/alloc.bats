#!/usr/bin/env bats
# next_free_ip USED... -> lowest unused IP in the 127.0.0.10-99 pool.

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/dev-ip-lib.sh"
}

@test "next_free_ip returns the lowest pool IP when none are used" {
  run next_free_ip
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.10" ]
}

@test "next_free_ip skips a used IP" {
  run next_free_ip 127.0.0.10
  [ "$output" = "127.0.0.11" ]
}

@test "next_free_ip fills the lowest gap" {
  run next_free_ip 127.0.0.10 127.0.0.12
  [ "$output" = "127.0.0.11" ]
}

@test "next_free_ip fails when the pool is exhausted" {
  run next_free_ip $(seq 10 99 | sed 's/^/127.0.0./')
  [ "$status" -ne 0 ]
}
