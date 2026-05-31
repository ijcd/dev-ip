#!/usr/bin/env bats
# Concurrent alloc must never hand two names the same IP (mkdir-lock).

setup() {
  export DEVIP_HOME="$BATS_TEST_TMPDIR/devip"
  DEVIP="${BATS_TEST_DIRNAME}/../bin/dev-ip"
}

@test "five concurrent allocs get five distinct IPs" {
  for n in a b c d e; do "$DEVIP" ip "$n" & done
  wait
  run bash -c "awk '{print \$1}' \"$DEVIP_HOME\"/hosts.d/* | sort -u | wc -l | tr -d ' '"
  [ "$output" = "5" ]
}

@test "a leftover .lock file does not wedge allocation (regression vs stale mkdir-lock)" {
  mkdir -p "$DEVIP_HOME/hosts.d"
  : > "$DEVIP_HOME/hosts.d/.lock"      # an unlocked lock target left by a prior run
  run "$DEVIP" ip web
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.10" ]         # allocates immediately, not blocked
}

@test "a crashed lock holder does not block the next allocation" {
  mkdir -p "$DEVIP_HOME/hosts.d"
  # a holder grabs the kernel lock then is kill -9'd while holding it;
  # the kernel must release it on the holder's death.
  bash -c 'exec 9>"'"$DEVIP_HOME"'/hosts.d/.lock"; perl -e "flock(STDIN,2) or exit 1" <&9; kill -9 $$' 2>/dev/null || true
  run "$DEVIP" ip web
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.10" ]
}

@test "twenty concurrent allocs get twenty distinct IPs" {
  for n in $(seq 1 20); do "$DEVIP" ip "n$n" & done
  wait
  run bash -c "awk '{print \$1}' \"$DEVIP_HOME\"/hosts.d/* | sort -u | wc -l | tr -d ' '"
  [ "$output" = "20" ]
}
