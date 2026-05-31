#!/usr/bin/env bash
# dev-ip functional core — pure functions, no IO / side effects.
# Sourced by bin/dev-ip (the imperative shell) and by test/*.bats.

# sanitize_name NAME -> a valid DNS label on stdout.
# lowercase; each run of non-[a-z0-9] -> one '-'; trim leading/trailing '-'; <=63.
sanitize_name() {
  local n
  n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  n=${n:0:63}
  printf '%s\n' "${n%-}"
}

# _pool_bounds -> "<start> <end>" from DEVIP_POOL_START/END (default 10 99).
# The pool is a last-octet sub-range of 127.0.0.x. Fails (stderr + non-zero)
# when either is non-numeric or the range violates 2 <= start <= end <= 254.
_pool_bounds() {
  local start="${DEVIP_POOL_START:-10}" end="${DEVIP_POOL_END:-99}"
  case "$start$end" in
    *[!0-9]*) echo "dev-ip: DEVIP_POOL_START/END must be numeric (got $start-$end)" >&2; return 1 ;;
  esac
  if [ "$start" -lt 2 ] || [ "$end" -gt 254 ] || [ "$start" -gt "$end" ]; then
    echo "dev-ip: DEVIP_POOL_START/END must satisfy 2 <= start <= end <= 254 (got $start-$end)" >&2
    return 1
  fi
  printf '%s %s\n' "$start" "$end"
}

# next_free_ip [USED_IP...] -> lowest unused IP in the pool on stdout.
# Exit 1 (nothing printed) if the pool is exhausted.
next_free_ip() {
  local used=" $* " o bounds start end
  bounds="$(_pool_bounds)" || return 1
  start="${bounds% *}"; end="${bounds#* }"
  for o in $(seq "$start" "$end"); do
    case $used in *" 127.0.0.$o "*) continue ;; esac
    printf '127.0.0.%s\n' "$o"
    return 0
  done
  return 1
}

# _hosts_dir -> the hosts.d registry path (filesystem seam; DEVIP_HOME redirects it).
_hosts_dir() { printf '%s\n' "${DEVIP_HOME:-$HOME/.local/share/dev-ip}/hosts.d"; }

# used_ips -> every currently-allocated IP, one per line (empty if none).
used_ips() {
  local d; d=$(_hosts_dir)
  [ -d "$d" ] || return 0
  awk '{print $1}' "$d"/* 2>/dev/null
  return 0
}

# _with_lock CMD [ARGS...] -> run CMD while holding an exclusive kernel lock on
# the hosts.d lock file. Uses perl's flock (macOS has no flock(1)); the lock is
# held by this shell's fd 9 and the kernel releases it when that fd closes —
# including on crash or kill -9 — so a stale lock is impossible. See ADR-0006.
_with_lock() {
  local lockfile rc
  mkdir -p "$(_hosts_dir)"
  lockfile="$(_hosts_dir)/.lock"
  exec 9>"$lockfile" || { echo "dev-ip: cannot open lock $lockfile" >&2; return 1; }
  # perl flocks the inherited fd (LOCK_EX=2), blocking up to 30s, then exits;
  # the lock stays held by our still-open fd 9.
  if ! perl -e '$SIG{ALRM} = sub { exit 1 }; alarm 30; flock(STDIN, 2) or exit 1' <&9; then
    echo "dev-ip: could not acquire lock $lockfile" >&2
    exec 9>&-
    return 1
  fi
  "$@"; rc=$?
  exec 9>&-
  return "$rc"
}

# alloc_ip NAME -> the IP for NAME on stdout, allocating + writing hosts.d/<label>
# on first use (dnsmasq format "IP label.tld"), stable on repeat. Exit 1 if pool full.
alloc_ip() {
  local label dir file tld="${DEVIP_TLD:-devip}"
  label=$(sanitize_name "$1")
  dir=$(_hosts_dir)
  file="$dir/$label"
  mkdir -p "$dir"
  if [ -f "$file" ]; then          # fast path: existing mapping, no lock needed
    awk '{print $1}' "$file"
    return 0
  fi
  _with_lock _alloc_new "$label" "$file" "$tld"
}

# _alloc_new LABEL FILE TLD -> pick lowest-free IP and write the mapping.
# Runs under _with_lock; re-checks the file in case a racer just created it.
_alloc_new() {
  local label="$1" file="$2" tld="$3" ip bounds
  if [ -f "$file" ]; then
    awk '{print $1}' "$file"
    return 0
  fi
  if ! ip=$(next_free_ip $(used_ips)); then
    bounds="$(_pool_bounds)"
    echo "dev-ip: IP pool 127.0.0.${bounds% *}-${bounds#* } exhausted" >&2
    return 1
  fi
  printf '%s %s.%s\n' "$ip" "$label" "$tld" > "$file"
  printf '%s\n' "$ip"
}

# free_name NAME -> remove the allocation (idempotent; missing is fine).
free_name() {
  rm -f "$(_hosts_dir)/$(sanitize_name "$1")"
}

# list_allocations -> one "label<TAB>IP" line per allocation (empty if none).
list_allocations() {
  local d f; d=$(_hosts_dir)
  [ -d "$d" ] || return 0
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    printf '%s\t%s\n' "$(basename "$f")" "$(awk '{print $1}' "$f")"
  done
}

# render_resolver -> content of /etc/resolver/<tld>: route the TLD to the
# dev-ip dnsmasq on 127.0.0.1:5354.
render_resolver() {
  printf 'nameserver 127.0.0.1\nport 5354\n'
}

# render_dnsmasq_plist DNSMASQ_PATH HOSTSDIR -> user LaunchAgent plist on stdout.
# Runs dnsmasq on 127.0.0.1:5354 serving only the hosts.d dir. Deterministic.
render_dnsmasq_plist() {
  local bin="$1" hostsdir="$2"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev-ip-dnsmasq</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bin}</string>
    <string>--keep-in-foreground</string>
    <string>--port=5354</string>
    <string>--listen-address=127.0.0.1</string>
    <string>--bind-interfaces</string>
    <string>--no-hosts</string>
    <string>--no-resolv</string>
    <string>--hostsdir=${hostsdir}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
}

# render_pf_anchor -> per-IP hairpin NAT rules for the configured pool.
# ONE rule per alias IP (never a /24 — a subnet rule breaks cross-IP traffic).
render_pf_anchor() {
  local o bounds start end
  bounds="$(_pool_bounds)" || return 1
  start="${bounds% *}"; end="${bounds#* }"
  for o in $(seq "$start" "$end"); do
    printf 'nat on lo0 from 127.0.0.%s to 127.0.0.%s -> 127.0.0.1\n' "$o" "$o"
  done
}

# render_loopback_plist -> root LaunchDaemon plist that adds lo0 aliases for the
# configured pool at boot. Root domain because `ifconfig lo0 alias` needs root.
render_loopback_plist() {
  local bounds start end
  bounds="$(_pool_bounds)" || return 1
  start="${bounds% *}"; end="${bounds#* }"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev-ip-loopback</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>for i in \$(seq $start $end); do /sbin/ifconfig lo0 alias 127.0.0.\$i up; done</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
}
