#!/usr/bin/env bats
# hosts.d registry: used_ips + alloc_ip (stable name->IP, writes dnsmasq-format file).
# DEVIP_HOME is redirected to a per-test temp dir (the filesystem seam).

setup() {
  export DEVIP_CONFIG="$BATS_TEST_TMPDIR/none.toml"   # isolate from the dev's real ~/.config
  source "${BATS_TEST_DIRNAME}/../lib/dev-ip-lib.sh"
  export DEVIP_HOME="$BATS_TEST_TMPDIR/devip"
}

@test "used_ips is empty when nothing is allocated" {
  run used_ips
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "alloc_ip assigns the lowest pool IP to a new name" {
  run alloc_ip gchs
  [ "$output" = "127.0.0.10" ]
}

@test "alloc_ip is stable: the same name always returns the same IP" {
  alloc_ip gchs
  run alloc_ip gchs
  [ "$output" = "127.0.0.10" ]
}

@test "alloc_ip gives distinct names distinct IPs" {
  alloc_ip gchs
  run alloc_ip other
  [ "$output" = "127.0.0.11" ]
}

@test "alloc_ip writes the hosts.d file in dnsmasq format" {
  alloc_ip gchs
  run cat "$DEVIP_HOME/hosts.d/gchs"
  [ "$output" = "127.0.0.10 gchs.devip" ]
}

@test "alloc_ip sanitizes the name for both label and filename" {
  run alloc_ip "Feature/Foo"
  [ "$output" = "127.0.0.10" ]
  [ -f "$DEVIP_HOME/hosts.d/feature-foo" ]
}

@test "used_ips reflects allocations" {
  alloc_ip gchs
  alloc_ip other
  run used_ips
  [[ "$output" == *"127.0.0.10"* ]]
  [[ "$output" == *"127.0.0.11"* ]]
}

@test "free_name removes the allocation" {
  alloc_ip gchs
  free_name gchs
  [ ! -f "$DEVIP_HOME/hosts.d/gchs" ]
}

@test "free_name is idempotent when the name does not exist" {
  run free_name nope
  [ "$status" -eq 0 ]
}

@test "freeing then re-allocating reuses the now-free IP" {
  alloc_ip gchs        # .10
  alloc_ip other       # .11
  free_name gchs       # frees .10
  run alloc_ip third
  [ "$output" = "127.0.0.10" ]
}

@test "list_allocations shows each name with its IP" {
  alloc_ip gchs
  alloc_ip other
  run list_allocations
  [[ "$output" == *gchs*127.0.0.10* ]]
  [[ "$output" == *other*127.0.0.11* ]]
}

@test "list_allocations is empty when nothing is allocated" {
  run list_allocations
  [ "$output" = "" ]
}
