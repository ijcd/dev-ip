#!/usr/bin/env bats
# The bin/dev-ip CLI shell — everyday no-sudo commands wired to the core.

setup() {
  export DEVIP_CONFIG="$BATS_TEST_TMPDIR/none.toml"   # isolate from the dev's real ~/.config
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

@test "dev-ip export prints an eval-able export line (default DEV_IP)" {
  run "$DEVIP" export my-app
  [ "$status" -eq 0 ]
  [ "$output" = "export DEV_IP=127.0.0.10" ]
}

@test "dev-ip export takes a custom variable name" {
  run "$DEVIP" export my-app MYIP
  [ "$output" = "export MYIP=127.0.0.10" ]
}

@test "dev-ip export is idempotent — same IP as ip" {
  a="$("$DEVIP" ip my-app)"
  run "$DEVIP" export my-app
  [ "$output" = "export DEV_IP=$a" ]
}

@test "dev-ip version / --version print the version" {
  run "$DEVIP" version;   [ "$output" = "dev-ip 0.1.1" ]
  run "$DEVIP" --version; [ "$output" = "dev-ip 0.1.1" ]
}

@test "dev-ip help shows usage (alias for --help)" {
  run "$DEVIP" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: dev-ip"* ]]
  [[ "$output" == *"export <name>"* ]]
}
