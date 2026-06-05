#!/usr/bin/env bats
# config registry: _config_keys (all 11 keys), _config_known_key (membership test)

setup() {
  DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  source "$DIR/lib/dev-ip-lib.sh"
}

@test "_config_keys lists all 11 keys with env + default columns" {
  run _config_keys
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 11 ]
  [[ "$output" == *"pool_start|DEVIP_POOL_START|10|"* ]]
  [[ "$output" == *"loopback_owner|DEVIP_LOOPBACK_OWNER|dev-ip|"* ]]
  [[ "$output" == *"pf_anchor_file|DEVIP_PF_ANCHOR_FILE|/etc/pf.anchors/dev-ip|"* ]]
}

@test "_config_known_key accepts a real key, rejects a bogus one" {
  run _config_known_key pool_start; [ "$status" -eq 0 ]
  run _config_known_key bogus;      [ "$status" -eq 1 ]
}

@test "_resolve_owner: only 'system' defers; everything else is dev-ip" {
  run _resolve_owner system;  [ "$output" = system ]
  run _resolve_owner dev-ip;  [ "$output" = dev-ip ]
  run _resolve_owner auto;    [ "$output" = dev-ip ]
  run _resolve_owner '';      [ "$output" = dev-ip ]
  run _resolve_owner garbage; [ "$output" = dev-ip ]
}

@test "_config_keys owner defaults are dev-ip" {
  run _config_keys
  [[ "$output" == *"loopback_owner|DEVIP_LOOPBACK_OWNER|dev-ip|"* ]]
  [[ "$output" == *"pf_owner|DEVIP_PF_OWNER|dev-ip|"* ]]
}

@test "_config_validate owner enum is dev-ip|system" {
  run _config_validate loopback_owner system;  [ "$status" -eq 0 ]
  run _config_validate loopback_owner dev-ip;  [ "$status" -eq 0 ]
  run _config_validate pf_owner auto;           [ "$status" -eq 1 ]
  run _config_validate loopback_owner nix;      [ "$status" -eq 1 ]
  [[ "$output" == *"dev-ip|system"* ]]
}

@test "_config_keys: every line has exactly 4 pipe-delimited fields" {
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$(printf '%s' "$line" | awk -F'|' '{print NF}')
    [ "$n" -eq 4 ] || { echo "line has $n fields, want 4: $line"; false; }
  done < <(_config_keys)
}

@test "parse_config reads flat kv, comments, quotes, whitespace" {
  cat >"$BATS_TEST_TMPDIR/c.toml" <<'EOF'
# a comment
pool_start = 100
tld="devtest"
  home = /tmp/x
not a kv line
EOF
  run parse_config "$BATS_TEST_TMPDIR/c.toml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pool_start=100"* ]]
  [[ "$output" == *"tld=devtest"* ]]
  [[ "$output" == *"home=/tmp/x"* ]]
  [[ "$output" != *"not a kv"* ]]
  [[ "$output" != *"# a comment"* ]]
}

@test "parse_config skips indented comments and blank lines" {
  printf '  # foo=bar\n\nkey=val\n' > "$BATS_TEST_TMPDIR/c.toml"
  run parse_config "$BATS_TEST_TMPDIR/c.toml"
  [ "$status" -eq 0 ]
  [ "$output" = "key=val" ]
}

@test "parse_config keeps everything after the first = in the value" {
  printf 'home = /tmp/x=y\n' > "$BATS_TEST_TMPDIR/c.toml"
  run parse_config "$BATS_TEST_TMPDIR/c.toml"
  [[ "$output" == *"home=/tmp/x=y"* ]]
}

@test "load_config: env beats file beats default, with provenance" {
  printf 'pool_start = 50\ntld = fromfile\n' > "$BATS_TEST_TMPDIR/c.toml"
  run env DEVIP_CONFIG="$BATS_TEST_TMPDIR/c.toml" DEVIP_POOL_START=77 bash -c '
    unset DEVIP_CONFIG_SOURCES DEVIP_TLD DEVIP_POOL_END
    source "'"$DIR"'/lib/dev-ip-lib.sh"
    load_config
    echo "ps=${DEVIP_POOL_START:-10} tld=${DEVIP_TLD:-devip} pe=${DEVIP_POOL_END:-99}"
    echo "src=$DEVIP_CONFIG_SOURCES"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ps=77"* ]]          # env beats file's 50
  [[ "$output" == *"tld=fromfile"* ]]   # file used
  [[ "$output" == *"pe=99"* ]]          # default
  [[ "$output" == *"pool_start=env"* ]]
  [[ "$output" == *"tld=config"* ]]
  [[ "$output" == *"pool_end=default"* ]]
}

@test "load_config idempotent (second call no-ops)" {
  run bash -c '
    unset DEVIP_CONFIG_SOURCES
    export DEVIP_CONFIG=/nonexistent
    source "'"$DIR"'/lib/dev-ip-lib.sh"
    load_config; A="$DEVIP_CONFIG_SOURCES"
    export DEVIP_POOL_START=5
    load_config
    [ "$DEVIP_CONFIG_SOURCES" = "$A" ] && echo IDEMPOTENT
  '
  [[ "$output" == *"IDEMPOTENT"* ]]
}

@test "config (bare) shows resolved values with source column" {
  printf 'tld = shown\n' > "$BATS_TEST_TMPDIR/c.toml"
  run env DEVIP_CONFIG="$BATS_TEST_TMPDIR/c.toml" DEVIP_POOL_START=77 \
    "$DIR/bin/dev-ip" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"pool_start"*"77"*"(env)"* ]]
  [[ "$output" == *"tld"*"shown"*"(config)"* ]]
  [[ "$output" == *"pool_end"*"99"*"(default)"* ]]
  [[ "$output" == *"config: $BATS_TEST_TMPDIR/c.toml"*"exists"* ]]
}

@test "config get: known key prints value; unknown key errors" {
  run env DEVIP_POOL_START=42 "$DIR/bin/dev-ip" config get pool_start
  [ "$status" -eq 0 ]; [ "$output" = "42" ]

  run "$DIR/bin/dev-ip" config get bogus
  [ "$status" -eq 1 ]; [[ "$output" == *"unknown config key: bogus"* ]]
}

@test "config set: upsert, create, validation, preserves other lines" {
  cfg="$BATS_TEST_TMPDIR/cfg/config.toml"
  # create + set a new key
  run env DEVIP_CONFIG="$cfg" "$DIR/bin/dev-ip" config set pool_start 100
  [ "$status" -eq 0 ]
  run env DEVIP_CONFIG="$cfg" "$DIR/bin/dev-ip" config get pool_start
  [ "$output" = "100" ]
  # freshly created file has no leading blank line
  run head -1 "$cfg"
  [ "$output" = "pool_start = 100" ]
  # upsert existing, and a second key is preserved
  env DEVIP_CONFIG="$cfg" "$DIR/bin/dev-ip" config set tld devtest
  env DEVIP_CONFIG="$cfg" "$DIR/bin/dev-ip" config set pool_start 120
  run cat "$cfg"
  [[ "$output" == *"pool_start = 120"* ]]
  [[ "$output" == *"tld = devtest"* ]]
  [[ "$output" != *"pool_start = 100"* ]]
  # validation
  run env DEVIP_CONFIG="$cfg" "$DIR/bin/dev-ip" config set pool_start 999
  [ "$status" -eq 1 ]; [[ "$output" == *"2-254"* ]]
  run env DEVIP_CONFIG="$cfg" "$DIR/bin/dev-ip" config set loopback_owner bogus
  [ "$status" -eq 1 ]; [[ "$output" == *"dev-ip|system"* ]]
  run env DEVIP_CONFIG="$cfg" "$DIR/bin/dev-ip" config set bogus x
  [ "$status" -eq 1 ]; [[ "$output" == *"unknown config key"* ]]
}

@test "config edit: seeds commented template when absent, then opens EDITOR" {
  cfg="$BATS_TEST_TMPDIR/cfg/config.toml"
  run env DEVIP_CONFIG="$cfg" EDITOR=true "$DIR/bin/dev-ip" config edit
  [ "$status" -eq 0 ]
  [ -f "$cfg" ]
  run cat "$cfg"
  [[ "$output" == *"# pool_start = 10"* ]]
  [[ "$output" == *"# loopback_owner = dev-ip"* ]]
}

@test "config edit: leaves an existing non-empty file's content" {
  cfg="$BATS_TEST_TMPDIR/cfg/config.toml"; mkdir -p "$(dirname "$cfg")"
  printf 'tld = keep\n' > "$cfg"
  env DEVIP_CONFIG="$cfg" EDITOR=true "$DIR/bin/dev-ip" config edit
  run cat "$cfg"; [ "$output" = "tld = keep" ]
}

@test "_config_keys covers every user-facing DEVIP_* the CLI reads (drift guard)" {
  # meta/test seams that are intentionally NOT user config keys:
  allow="DEVIP_CONFIG DEVIP_CONFIG_SOURCES DEVIP_LIB DEVIP_CALL_LOG DEVIP_STUB_ROUTE DEVIP_STUB_PF_ENABLED DEVIP_STUB_PF_LOADED DEVIP_STUB_SYSRESOLVE"
  reg="$(_config_keys | cut -d'|' -f2)"
  bad=""
  for v in $(grep -rhoE 'DEVIP_[A-Z_]+' "$DIR/bin/dev-ip" "$DIR/lib/dev-ip-lib.sh" | sort -u); do
    printf '%s\n' "$reg" | grep -qx "$v" && continue
    case " $allow " in *" $v "*) continue ;; esac
    bad="$bad $v"
  done
  [ -z "$bad" ] || { echo "DEVIP_* not in registry or allowlist:$bad"; false; }
}
