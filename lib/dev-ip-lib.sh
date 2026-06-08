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

# ip_to_int A.B.C.D -> 32-bit integer; int_to_ip reverses it. Pure. Lets the
# pool span the whole 127/8, not just the last octet of one /24.
ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<EOF
$1
EOF
  printf '%s\n' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}
int_to_ip() {
  local n="$1"
  printf '%s.%s.%s.%s\n' "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" "$(( (n >> 8) & 255 ))" "$(( n & 255 ))"
}

# _pool_addr X -> a full 127.x IP. A bare integer N is shorthand for 127.0.0.N
# (back-compat with the old last-octet form); a dotted quad passes through.
_pool_addr() {
  case "$1" in
    *.*) printf '%s\n' "$1" ;;
    *)   printf '127.0.0.%s\n' "$1" ;;
  esac
}

# _valid_pool_ip IP -> 0 if IP is a dotted quad in 127.0.0.0/8 (octets 0-255).
_valid_pool_ip() {
  local a b c d o
  case "$1" in *.*.*.*) ;; *) return 1 ;; esac
  IFS=. read -r a b c d <<EOF
$1
EOF
  [ "$a" = 127 ] || return 1
  for o in "$b" "$c" "$d"; do
    case "$o" in ''|*[!0-9]*) return 1 ;; esac
    [ "$o" -le 255 ] || return 1
  done
  return 0
}

# _pool_bounds -> "<start-ip> <end-ip>" (full 127/8 IPs) from DEVIP_POOL_START/END
# (default 10 99 = 127.0.0.10-99). Each bound is a bare octet OR a 127.x IP.
# Fails outside 127.0.0.2 .. 127.255.255.254, on start>end, or when the range
# exceeds DEVIP_POOL_MAX (default 65536) — provision writes one pf rule + lo0
# alias per IP, so an unbounded range would blow up the anchor.
_pool_bounds() {
  local start end si ei lo hi cap
  start="$(_pool_addr "${DEVIP_POOL_START:-10}")"
  end="$(_pool_addr "${DEVIP_POOL_END:-99}")"
  if ! _valid_pool_ip "$start" || ! _valid_pool_ip "$end"; then
    echo "dev-ip: DEVIP_POOL_START/END must be an integer or a 127.x.x.x address (got $start $end)" >&2
    return 1
  fi
  si="$(ip_to_int "$start")"; ei="$(ip_to_int "$end")"
  lo="$(ip_to_int 127.0.0.2)"; hi="$(ip_to_int 127.255.255.254)"
  cap="${DEVIP_POOL_MAX:-65536}"
  if [ "$si" -lt "$lo" ] || [ "$ei" -gt "$hi" ] || [ "$si" -gt "$ei" ]; then
    echo "dev-ip: pool must satisfy 127.0.0.2 <= start <= end <= 127.255.255.254 (got $start-$end)" >&2
    return 1
  fi
  if [ "$(( ei - si + 1 ))" -gt "$cap" ]; then
    echo "dev-ip: pool $start-$end = $(( ei - si + 1 )) IPs exceeds DEVIP_POOL_MAX=$cap (one pf rule + lo0 alias per IP)" >&2
    return 1
  fi
  printf '%s %s\n' "$start" "$end"
}

# next_free_ip [USED_IP...] -> lowest unused IP in the pool on stdout.
# Exit 1 (nothing printed) if the pool is exhausted.
next_free_ip() {
  local used=" $* " bounds start end n ei ip
  bounds="$(_pool_bounds)" || return 1
  start="${bounds% *}"; end="${bounds#* }"
  n="$(ip_to_int "$start")"; ei="$(ip_to_int "$end")"
  while [ "$n" -le "$ei" ]; do
    ip="$(int_to_ip "$n")"
    case $used in *" $ip "*) ;; *) printf '%s\n' "$ip"; return 0 ;; esac
    n=$(( n + 1 ))
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
    echo "dev-ip: IP pool ${bounds% *}-${bounds#* } exhausted" >&2
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
    <string>--addn-hosts=${hostsdir}</string>
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
  local bounds start end n ei ip
  bounds="$(_pool_bounds)" || return 1
  start="${bounds% *}"; end="${bounds#* }"
  n="$(ip_to_int "$start")"; ei="$(ip_to_int "$end")"
  while [ "$n" -le "$ei" ]; do
    ip="$(int_to_ip "$n")"
    printf 'nat on lo0 from %s to %s -> 127.0.0.1\n' "$ip" "$ip"
    n=$(( n + 1 ))
  done
}

# render_pf_conf_add ANCHOR_FILE -> stdin pf.conf to stdout with dev-ip's
# `nat-anchor` + `load anchor` inserted in the TRANSLATION section (before the
# first rdr-anchor / filter line), NOT appended at the end. pf enforces rule
# order (options, scrub, queue, nat/rdr, filter); appending a nat-anchor after
# the trailing `anchor "com.apple/*"` filter anchor is a syntax error on a real
# macOS pf.conf. If no translation/filter boundary is found, append.
render_pf_conf_add() {
  awk -v a="$1" '
    !ins && /^(rdr-anchor|dummynet-anchor|anchor[ "]|block|pass)/ {
      print "nat-anchor \"dev-ip\""
      print "load anchor \"dev-ip\" from \"" a "\""
      ins = 1
    }
    { print }
    END { if (!ins) { print "nat-anchor \"dev-ip\""; print "load anchor \"dev-ip\" from \"" a "\"" } }
  '
}

# render_loopback_plist -> root LaunchDaemon plist that adds lo0 aliases for the
# configured pool at boot. Root domain because `ifconfig lo0 alias` needs root.
render_loopback_plist() {
  local bounds start end n ei ips
  bounds="$(_pool_bounds)" || return 1
  start="${bounds% *}"; end="${bounds#* }"
  n="$(ip_to_int "$start")"; ei="$(ip_to_int "$end")"
  ips=""
  while [ "$n" -le "$ei" ]; do ips="$ips $(int_to_ip "$n")"; n=$(( n + 1 )); done
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
    <string>for ip in$ips; do /sbin/ifconfig lo0 alias \$ip up; done</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
}

# _config_keys -> one "key|env|default|description" line per config setting.
# Single source of truth (bash 3.2 has no assoc arrays). $HOME expands here.
_config_keys() {
  cat <<EOF
pool_start|DEVIP_POOL_START|10|pool start — bare int (=127.0.0.N) or a 127.x IP
pool_end|DEVIP_POOL_END|99|pool end — bare int (=127.0.0.N) or a 127.x IP
pool_max|DEVIP_POOL_MAX|65536|max pool size in IPs (caps per-IP pf/alias cost)
dnsmasq_bin|DEVIP_DNSMASQ_BIN||dnsmasq binary (blank = prefer brew's, else PATH)
tld|DEVIP_TLD|devip|resolver TLD served by dnsmasq
home|DEVIP_HOME|$HOME/.local/share/dev-ip|registry (hosts.d) location
loopback_owner|DEVIP_LOOPBACK_OWNER|dev-ip|who manages lo0 aliases (dev-ip/system)
pf_owner|DEVIP_PF_OWNER|dev-ip|who manages pf hairpin (dev-ip/system)
resolver_dir|DEVIP_RESOLVER_DIR|/etc/resolver|/etc/resolver dir
launchagents|DEVIP_LAUNCHAGENTS|$HOME/Library/LaunchAgents|user LaunchAgents dir
launchdaemons|DEVIP_LAUNCHDAEMONS|/Library/LaunchDaemons|root LaunchDaemons dir
pf_conf|DEVIP_PF_CONF|/etc/pf.conf|pf.conf path
pf_anchor_file|DEVIP_PF_ANCHOR_FILE|/etc/pf.anchors/dev-ip|pf anchor file path
EOF
}

# _config_known_key KEY -> 0 if KEY is a registry key.
_config_known_key() {
  local k rest
  while IFS='|' read -r k rest; do [ "$k" = "$1" ] && return 0; done <<EOF
$(_config_keys)
EOF
  return 1
}

# parse_config FILE -> "key=value" lines for the flat TOML subset.
# blank / #-comment lines skipped; needs '='; trims ws; strips one "" layer.
parse_config() {
  local file="$1" line key val
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # skip blank and (possibly indented) full-line comments
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; esac
    [ -n "$key" ] && printf '%s=%s\n' "$key" "$val"
  done < "$file"
}

# _config_path -> the resolved config file path (single source of truth).
_config_path() {
  printf '%s\n' "${DEVIP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/dev-ip/config.toml}"
}

# load_config -> populate DEVIP_* from the config file (export-if-unset), env
# wins. Records DEVIP_CONFIG_SOURCES="key=env|config|default ...". Idempotent.
load_config() {
  [ -n "${DEVIP_CONFIG_SOURCES:-}" ] && return 0
  local cfg; cfg="$(_config_path)"
  local parsed="" srcs="" key env def desc fileval
  [ -f "$cfg" ] && parsed="$(parse_config "$cfg")"
  while IFS='|' read -r key env def desc; do
    [ -n "$key" ] || continue
    if printenv "$env" >/dev/null 2>&1; then
      srcs="${srcs}${key}=env "
    elif printf '%s\n' "$parsed" | grep -q "^${key}="; then
      fileval="$(printf '%s\n' "$parsed" | sed -n "s/^${key}=//p" | head -1)"
      export "$env=$fileval"
      srcs="${srcs}${key}=config "
    else
      srcs="${srcs}${key}=default "
    fi
  done <<EOF
$(_config_keys)
EOF
  export DEVIP_CONFIG_SOURCES="$srcs"
}

# _config_validate KEY VALUE -> 0 if valid; stderr + 1 otherwise (also the
# unknown-key gate). Simple checks only.
_config_validate() {
  local key="$1" val="$2"
  case "$key" in
    pool_start|pool_end)
      # a bare octet (2-254) OR a full 127.x IP
      case "$val" in
        *.*) _valid_pool_ip "$val" || { echo "dev-ip: $key must be a 127.x.x.x address" >&2; return 1; } ;;
        ''|*[!0-9]*) echo "dev-ip: $key must be an integer (2-254) or a 127.x IP" >&2; return 1 ;;
        *) { [ "$val" -ge 2 ] && [ "$val" -le 254 ]; } || { echo "dev-ip: $key octet must be 2-254 (or use a full 127.x IP)" >&2; return 1; } ;;
      esac ;;
    pool_max)
      case "$val" in ''|*[!0-9]*) echo "dev-ip: pool_max must be a positive integer" >&2; return 1 ;; esac
      [ "$val" -ge 1 ] || { echo "dev-ip: pool_max must be >= 1" >&2; return 1; } ;;
    dnsmasq_bin)
      [ -n "$val" ] || { echo "dev-ip: dnsmasq_bin must be a path (or unset to auto-detect)" >&2; return 1; } ;;
    loopback_owner|pf_owner)
      case "$val" in dev-ip|system) ;; *) echo "dev-ip: $key must be dev-ip|system" >&2; return 1 ;; esac ;;
    tld)
      case "$val" in ''|*[!a-z0-9-]*) echo "dev-ip: $key must be DNS-label chars [a-z0-9-]" >&2; return 1 ;; esac ;;
    home|resolver_dir|launchagents|launchdaemons|pf_conf|pf_anchor_file)
      [ -n "$val" ] || { echo "dev-ip: $key must be non-empty" >&2; return 1; } ;;
    *) echo "dev-ip: unknown config key: $key" >&2; return 1 ;;
  esac
}

# render_config_upsert KEY VALUE -> stdin config text to stdout with KEY set.
render_config_upsert() {
  local key="$1" val="$2" replaced=0 line first
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#*) printf '%s\n' "$line"; continue ;;
    esac
    first="$(printf '%s' "${line%%=*}" | sed -E 's/[[:space:]]//g')"
    if [ "$first" = "$key" ] && case "$line" in *=*) true ;; *) false ;; esac; then
      printf '%s = %s\n' "$key" "$val"; replaced=1
    else
      printf '%s\n' "$line"
    fi
  done
  [ "$replaced" -eq 0 ] && printf '%s = %s\n' "$key" "$val"
  return 0
}

# render_config_template -> commented starter config from the key registry.
render_config_template() {
  local key env def desc
  printf '# dev-ip config — flat TOML subset. Uncomment + edit a line to set it.\n'
  printf '# Env vars (DEVIP_*) override anything here.\n\n'
  while IFS='|' read -r key env def desc; do
    [ -n "$key" ] || continue
    printf '# %s\n# %s = %s\n\n' "$desc" "$key" "$def"
  done <<EOF
$(_config_keys)
EOF
}

# _resolve_owner VALUE -> dev-ip | system. Only the literal 'system' defers;
# empty, 'dev-ip', legacy 'auto'/'nix', or anything else -> dev-ip (self-manage,
# the safe default). No host detection.
_resolve_owner() {
  case "$1" in
    system) printf 'system\n' ;;
    *)      printf 'dev-ip\n' ;;
  esac
}
