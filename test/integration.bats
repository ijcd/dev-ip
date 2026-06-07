#!/usr/bin/env bats
# Real dnsmasq + dig — the layer-3 resolution flow the stub suite CANNOT cover.
# This is the net that would have caught --hostsdir (unsupported on macOS): it
# runs an actual dnsmasq with dev-ip's resolution flags and asserts it answers.
# Uses :5355 + a temp hosts.d so it never touches a running dev-ip agent.
# Skips when no dnsmasq/dig is installed; no root, no VM.

setup() {
  export DEVIP_CONFIG="$BATS_TEST_TMPDIR/none.toml"
  DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  DM=""
  for c in /opt/homebrew/opt/dnsmasq/sbin/dnsmasq /usr/local/opt/dnsmasq/sbin/dnsmasq "$(command -v dnsmasq 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && { DM="$c"; break; }
  done
  [ -n "$DM" ] || skip "no dnsmasq installed"
  command -v dig >/dev/null 2>&1 || skip "no dig installed"
  HD="$BATS_TEST_TMPDIR/hosts.d"; mkdir -p "$HD"
  PORT=5355
  pkill -f "port=$PORT" 2>/dev/null || true   # clear any leftover
  PID=""
}
teardown() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null; pkill -f "port=$PORT" 2>/dev/null || true; }

# _wait_bound -> 0 once dnsmasq is listening; fails the caller (with stderr) if it dies.
_wait_bound() {
  local i
  for i in $(seq 1 25); do
    kill -0 "$PID" 2>/dev/null || { echo "dnsmasq exited early: $(cat "$BATS_TEST_TMPDIR/dm.err")"; return 1; }
    lsof -nP -iUDP:"$PORT" 2>/dev/null | grep -q dnsmasq && return 0
    dig @127.0.0.1 -p "$PORT" _wait.devip +time=1 +tries=1 >/dev/null 2>&1 || true   # ~1s tick, no sleep
  done
  echo "dnsmasq never bound :$PORT"; return 1
}

# _resolves NAME IP -> 0 once dnsmasq answers NAME with IP (bounded)
_resolves() {
  local i r
  for i in $(seq 1 10); do
    r="$(dig @127.0.0.1 -p "$PORT" "$1" +short +time=1 +tries=1 2>/dev/null)"
    [ "$r" = "$2" ] && return 0
  done
  echo "$1 resolved to '${r:-}' , wanted $2"; return 1
}

@test "real dnsmasq serves allocated names via dev-ip's flags, and SIGHUP reloads" {
  printf '127.0.0.77 alpha.devip\n' > "$HD/alpha"
  "$DM" --keep-in-foreground --listen-address=127.0.0.1 --bind-interfaces \
        --no-hosts --no-resolv --addn-hosts="$HD" --port="$PORT" 2>"$BATS_TEST_TMPDIR/dm.err" &
  PID=$!
  _wait_bound                       # if a flag were unsupported, dnsmasq exits here
  _resolves alpha.devip 127.0.0.77  # existing allocation resolves
  printf '127.0.0.88 beta.devip\n' > "$HD/beta"   # a fresh `dev-ip ip`
  kill -HUP "$PID"                  # what _reload_dnsmasq does
  _resolves beta.devip 127.0.0.88   # picked up live
}
