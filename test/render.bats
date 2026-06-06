#!/usr/bin/env bats
# Content renderers: pure, deterministic strings (the "deterministic content"
# requirement — a rewrite is a safe no-op when unchanged).

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/dev-ip-lib.sh"
}

@test "render_resolver points a resolver at the dev-ip dnsmasq (127.0.0.1:5354)" {
  run render_resolver
  [ "$output" = "nameserver 127.0.0.1
port 5354" ]
}

@test "render_resolver is deterministic (byte-identical across calls)" {
  a=$(render_resolver)
  b=$(render_resolver)
  [ "$a" = "$b" ]
}

@test "render_dnsmasq_plist embeds the dnsmasq path, :5354 args, and hostsdir" {
  run render_dnsmasq_plist /opt/homebrew/bin/dnsmasq /tmp/hd/hosts.d
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>dev-ip-dnsmasq</string>"* ]]
  [[ "$output" == *"<string>/opt/homebrew/bin/dnsmasq</string>"* ]]
  [[ "$output" == *"<string>--port=5354</string>"* ]]
  [[ "$output" == *"<string>--hostsdir=/tmp/hd/hosts.d</string>"* ]]
  [[ "$output" == *"<string>--no-hosts</string>"* ]]
  [[ "$output" == *"<string>--no-resolv</string>"* ]]
}

@test "render_dnsmasq_plist is deterministic" {
  a=$(render_dnsmasq_plist /x/dnsmasq /y/hosts.d)
  b=$(render_dnsmasq_plist /x/dnsmasq /y/hosts.d)
  [ "$a" = "$b" ]
}

@test "render_pf_anchor emits one per-IP hairpin NAT line for the whole pool" {
  run render_pf_anchor
  [ "$status" -eq 0 ]
  # exactly 90 rules, .10 through .99
  [ "$(printf '%s\n' "$output" | grep -c '^nat on lo0 ')" -eq 90 ]
  [[ "$output" == *"nat on lo0 from 127.0.0.10 to 127.0.0.10 -> 127.0.0.1"* ]]
  [[ "$output" == *"nat on lo0 from 127.0.0.99 to 127.0.0.99 -> 127.0.0.1"* ]]
}

@test "render_pf_anchor never emits a subnet rule" {
  run render_pf_anchor
  [[ "$output" != *"/24"* ]]
}

@test "render_loopback_plist is a boot daemon that aliases the pool on lo0" {
  run render_loopback_plist
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>dev-ip-loopback</string>"* ]]
  [[ "$output" == *'alias $ip up'* ]]
  [[ "$output" == *"<key>RunAtLoad</key><true/>"* ]]
  [[ "$output" == *"for ip in "* ]]
  [[ "$output" == *"127.0.0.99;"* ]]   # explicit IP list ends at the range end
}

@test "render_loopback_plist is deterministic" {
  a=$(render_loopback_plist); b=$(render_loopback_plist)
  [ "$a" = "$b" ]
}

@test "render_pf_anchor honors the configured pool range" {
  export DEVIP_POOL_START=100 DEVIP_POOL_END=102
  run render_pf_anchor
  [ "$(printf '%s\n' "$output" | grep -c '^nat on lo0 ')" -eq 3 ]
  [[ "$output" == *"127.0.0.100 to 127.0.0.100"* ]]
  [[ "$output" == *"127.0.0.102 to 127.0.0.102"* ]]
  [[ "$output" != *"127.0.0.10 to"* ]]
}

@test "render_loopback_plist honors the configured pool range" {
  export DEVIP_POOL_START=100 DEVIP_POOL_END=199
  run render_loopback_plist
  [[ "$output" == *"127.0.0.100 "* ]]     # range start aliased
  [[ "$output" == *"127.0.0.199;"* ]]     # range end aliased
  [[ "$output" == *'alias $ip up'* ]]
  [[ "$output" != *"127.0.0.50"* ]]       # out-of-range not included
}
