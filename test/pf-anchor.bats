#!/usr/bin/env bats
# Real pfctl -nf — validates that dev-ip's pf.conf insertion respects pf rule
# ordering. The bug: `step_pf` appended `nat-anchor "dev-ip"` to the END of
# /etc/pf.conf, but pf requires translation rules BEFORE filter rules, so on a
# stock Mac (filter `anchor "com.apple/*"` near the end) `pfctl -f` failed with
# "Rules must be in order". The stub suite can't see this — pfctl -nf just
# parses (no root), so this runs it for real. Skips without pfctl / pf.conf.

setup() {
  export DEVIP_CONFIG="$BATS_TEST_TMPDIR/none.toml"
  source "${BATS_TEST_DIRNAME}/../lib/dev-ip-lib.sh"
  command -v pfctl >/dev/null 2>&1 || skip "no pfctl"
  [ -r /etc/pf.conf ] || skip "no readable /etc/pf.conf"
  ANCHOR="$BATS_TEST_TMPDIR/dev-ip.anchor"
  printf 'nat on lo0 from 127.0.0.10 to 127.0.0.10 -> 127.0.0.1\n' > "$ANCHOR"
}

@test "dev-ip's nat-anchor inserted into the real /etc/pf.conf parses clean" {
  conf="$BATS_TEST_TMPDIR/pf.conf"
  render_pf_conf_add "$ANCHOR" < /etc/pf.conf > "$conf"
  run pfctl -nf "$conf"
  [[ "$output" != *"must be in order"* ]]      # the exact failure from a real Mac
  [[ "$output" != *"pf rules not loaded"* ]]
}

@test "the old append-at-end approach really does fail ordering (guard is meaningful)" {
  grep -qE '^anchor ' /etc/pf.conf || skip "this pf.conf has no filter anchor to violate"
  conf="$BATS_TEST_TMPDIR/pf.conf"; cp /etc/pf.conf "$conf"
  printf 'nat-anchor "dev-ip"\nload anchor "dev-ip" from "%s"\n' "$ANCHOR" >> "$conf"
  run pfctl -nf "$conf"
  [[ "$output" == *"must be in order"* ]]
}
