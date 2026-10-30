#!/usr/bin/env bats
# ~/.atst/config in the KEY=VALUE form (#134): atst_config_parse (lib/atst_config.sh) takes a config whose
# every line is in the form and assigns it without running it; any other config (the template as it
# is) is read as bash, as before. doctor.sh tells which form is in use.
# The parser is called through common.sh (lib/ is never read on its own); the sandbox config stays the
# template (old form) unless a test writes another one.

load test_helper

setup() {
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  F="$ATST_TEST_SANDBOX/cfg"
}

teardown() {
  atst_test_teardown_sandbox
}

# cfg_parse <file> <var>...
# Reads common.sh, then runs atst_config_parse <file> and prints "rc=<n> fmt=<format> line=<line>" and
# `declare -p` (or "unset <var>") of each <var>.
cfg_parse() {
  run env LC_ALL=C bash -c '. "$1" >/dev/null 2>&1; f=$2; shift 2; atst_config_parse "$f"; echo "rc=$? fmt=$ATST_CONFIG_FORMAT line=$ATST_CONFIG_FORMAT_LINE"; for v; do declare -p "$v" 2>/dev/null || echo "unset $v"; done' _ "$repo/common.sh" "$@"
}

# cfg_reject <line>
# <line> as line 3 of a file whose other lines are in the form: the file is the old form, line 3 is
# named, and nothing is assigned (not even line 2).
cfg_reject() {
  printf '# head\nATST_CFG_PRE=1\n%s\nATST_CFG_POST=2\n' "$1" > "$F"
  cfg_parse "$F" ATST_CFG_PRE ATST_CFG_POST
  [ "${lines[0]}" = "rc=1 fmt=legacy line=3" ]
  [ "${lines[1]}" = "unset ATST_CFG_PRE" ]
  [ "${lines[2]}" = "unset ATST_CFG_POST" ]
}

# cfg_source <code>: as cf_source of common.bats (no ERR trap, no set -e, as from cron).
cfg_source() {
  run env LC_ALL=C bash -c '. "$1" || exit 9; echo after-source; '"$1" _ "$repo/common.sh"
}

cfg_warn_count() {
  printf '%s\n' "$output" | grep -c '^\[warn\] ~/.atst/config may not have been read completely'
}

# cfg_strict_from_template <dst>
# templates/config without its lines of bash code (ATST_CONFIG_DIR=... to export ...): comments,
# KEY=number, KEY="..." and ATST_TARGETS=('Land Prime') only, i.e. the same settings in the KEY=VALUE form.
cfg_strict_from_template() {
  sed '/^ATST_CONFIG_DIR=/,/^export WINEARCH/d' "$repo/templates/config" > "$1"
}

# Prints declare -p of every ATST_* / WINE* / DISPLAY variable but ATST_CONFIG_FORMAT* after common.sh,
# in a cron-like environment (env -i). Extra "NAME=value" arguments go to the environment.
cfg_dump() {
  env -i HOME="$HOME" PATH=/usr/bin:/bin "$@" bash -c '. "$1" >/dev/null 2>&1; echo "fmt=$ATST_CONFIG_FORMAT"; for v in $(compgen -v); do case $v in ATST_CONFIG_FORMAT*) ;; ATST_*|WINE*|DISPLAY) declare -p "$v" ;; esac; done' _ "$repo/common.sh"
}

@test "CFG-01: blank lines and lines of spaces or tabs are skipped (a)" {
  printf '\n   \n\t\n \t \nATST_X=1\n' > "$F"
  cfg_parse "$F" ATST_X
  [ "${lines[0]}" = "rc=0 fmt=strict line=" ]
  [ "${lines[1]}" = 'declare -- ATST_X="1"' ]
}

@test "CFG-02: comment lines, also after spaces, are skipped (b)" {
  printf '# x\n   # x y\n\t#\nATST_X=1\n' > "$F"
  cfg_parse "$F" ATST_X
  [ "${lines[0]}" = "rc=0 fmt=strict line=" ]
}

@test "CFG-03: KEY=value without quotes, an empty value and trailing blanks (c)" {
  printf 'ATST_CHECK_TIMEOUT=40\nATST_HEARTBEAT_URL=\nWINEDEBUG=-all,err+all \t\n' > "$F"
  cfg_parse "$F" ATST_CHECK_TIMEOUT ATST_HEARTBEAT_URL WINEDEBUG
  [ "${lines[0]}" = "rc=0 fmt=strict line=" ]
  [ "${lines[1]}" = 'declare -- ATST_CHECK_TIMEOUT="40"' ]
  [ "${lines[2]}" = 'declare -- ATST_HEARTBEAT_URL=""' ]
  # WINEDEBUG is exported already (the sandbox config is the template); only its value is compared.
  [[ "${lines[3]}" == *' WINEDEBUG="-all,err+all"' ]]
}

@test "CFG-04: KEY=\"value\" gives what is inside the quotes (d)" {
  printf '%s\n' 'ATST_HEARTBEAT_URL="https://hc-ping.com/xxxx"' 'WINEDLLOVERRIDES="mscoree=;mshtml="' 'ATST_Y="a b; c|d"' > "$F"
  cfg_parse "$F" ATST_HEARTBEAT_URL WINEDLLOVERRIDES ATST_Y
  [ "${lines[0]}" = "rc=0 fmt=strict line=" ]
  [ "${lines[1]}" = 'declare -- ATST_HEARTBEAT_URL="https://hc-ping.com/xxxx"' ]
  [[ "${lines[2]}" == *'WINEDLLOVERRIDES="mscoree=;mshtml="' ]]
  [ "${lines[3]}" = 'declare -- ATST_Y="a b; c|d"' ]
}

@test "CFG-05: KEY='value' gives what is inside the quotes, a backslash as it is (e)" {
  printf '%s\n' "ATST_X='a b'" "ATST_Y='a\\b'" > "$F"
  cfg_parse "$F" ATST_X ATST_Y
  [ "${lines[0]}" = "rc=0 fmt=strict line=" ]
  [ "${lines[1]}" = 'declare -- ATST_X="a b"' ]
  [ "${lines[2]}" = 'declare -- ATST_Y="a\\b"' ]
}

@test "CFG-06: ATST_TARGETS=( ... ) on one line keeps its elements; () is an empty array (f)" {
  printf '%s\n' "ATST_TARGETS=('Land Prime' \"MetaTrader 5\")" > "$F"
  cfg_parse "$F" ATST_TARGETS
  [ "${lines[0]}" = "rc=0 fmt=strict line=" ]
  [ "${lines[1]}" = 'declare -a ATST_TARGETS=([0]="Land Prime" [1]="MetaTrader 5")' ]
  printf '%s\n' 'ATST_TARGETS=()' > "$F"
  cfg_parse "$F" ATST_TARGETS
  [ "${lines[0]}" = "rc=0 fmt=strict line=" ]
  [ "${lines[1]}" = 'declare -a ATST_TARGETS=()' ]
}

@test "CFG-07: the later line of the same key wins" {
  printf '%s\n' 'ATST_X=1' 'ATST_X="2"' "ATST_TARGETS=('a')" "ATST_TARGETS=('b' 'c')" > "$F"
  cfg_parse "$F" ATST_X ATST_TARGETS
  [ "${lines[1]}" = 'declare -- ATST_X="2"' ]
  [ "${lines[2]}" = 'declare -a ATST_TARGETS=([0]="b" [1]="c")' ]
}

@test "CFG-08: a last line without a newline is read" {
  printf '# x\nATST_X=1' > "$F"
  cfg_parse "$F" ATST_X
  [ "${lines[0]}" = "rc=0 fmt=strict line=" ]
  [ "${lines[1]}" = 'declare -- ATST_X="1"' ]
}

@test "CFG-R01: export X=1 is not in the form" { cfg_reject 'export ATST_X=1'; }
@test "CFG-R02: a \$ expansion is not in the form" { cfg_reject 'ATST_X=$HOME/.wine'; }
@test "CFG-R03: a command substitution is not in the form" { cfg_reject 'ATST_X=$(cat f)'; }
@test "CFG-R04: an unquoted blank in the value is not in the form" { cfg_reject 'ATST_X=a b'; }
@test "CFG-R05: a comment after the value is not in the form" { cfg_reject 'ATST_X=a # c'; }
@test "CFG-R06: a blank after = is not in the form" { cfg_reject 'ATST_X= 1'; }
@test "CFG-R07: a blank before = is not in the form" { cfg_reject 'ATST_X =1'; }
@test "CFG-R08: a lower-case key is not in the form" { cfg_reject 'atst_x=1'; }
@test "CFG-R09: a key outside the allowed names is not in the form" { cfg_reject 'LANG=C'; }
@test "CFG-R10: a backslash inside double quotes is not in the form" { cfg_reject 'ATST_X="a\"b"'; }
@test "CFG-R11: \$'...' is not in the form" { cfg_reject "ATST_X=\$'a'"; }
@test "CFG-R12: a backslash escape without quotes is not in the form" { cfg_reject 'ATST_X=a\ b'; }
@test "CFG-R13: an unquoted ATST_TARGETS element is not in the form" { cfg_reject 'ATST_TARGETS=(a)'; }
@test "CFG-R14: an indexed ATST_TARGETS element is not in the form" { cfg_reject 'ATST_TARGETS=([1]=a)'; }
@test "CFG-R15: an ATST_TARGETS over more than one line is not in the form" { cfg_reject "ATST_TARGETS=('a'"; }
@test "CFG-R16: if is not in the form" { cfg_reject 'if [ -z "$X" ]; then'; }
@test "CFG-R17: echo is not in the form" { cfg_reject 'echo x'; }
@test "CFG-R18: a key common.sh sets is not in the form" { cfg_reject 'ATST_CONFIG_DIR=/x'; }
@test "CFG-R19: a line with a CR is not in the form" { cfg_reject $'ATST_X=1\r'; }
@test "CFG-R20: ATST_TARGETS elements without a blank between are not in the form" { cfg_reject 'ATST_TARGETS=("a""b")'; }
@test "CFG-R21: a scalar ATST_TARGETS is not in the form" { cfg_reject 'ATST_TARGETS=x'; }

@test "CFG-09: a file it cannot read is the old form, line 0, and nothing is printed" {
  mkdir -p "$F"
  cfg_parse "$F"
  [ "$output" = "rc=1 fmt=legacy line=0" ]
}

@test "CFG-10: the parser prints nothing and leaves no variable but the assigned keys behind" {
  local code='. "$1" >/dev/null 2>&1; a=$(compgen -v); o=$(atst_config_parse "$2" 2>&1); atst_config_parse "$2"; echo "out=[$o]"; comm -13 <(printf "%s\n" "$a" | sort) <(compgen -v | sort) | grep -vx -e a -e o; :'
  printf '%s\n' 'ATST_CFG_NEW=1' "ATST_TARGETS=('a')" > "$F"
  run bash -c "$code" _ "$repo/common.sh" "$F"
  [ "$status" -eq 0 ]
  # ATST_TARGETS is there already (the sandbox config is the template), so only ATST_CFG_NEW is new.
  [ "$output" = "$(printf '%s\n' 'out=[]' ATST_CFG_NEW)" ]
  printf '%s\n' 'ATST_CFG_NEW=1' 'echo x' > "$F"
  run bash -c "$code" _ "$repo/common.sh" "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "out=[]" ]
}

@test "CFG-11: the template and the same settings in the KEY=VALUE form give the same variables and exports" {
  local old new
  mkdir -p "$HOME/.atst" "$HOME/.wine"
  printf 'WINE REGISTRY Version 2\n#arch=win32\n' > "$HOME/.wine/system.reg"
  printf 'tok\n' > "$HOME/.atst/.line_token"
  printf 'uid\n' > "$HOME/.atst/.line_id"
  cp "$repo/templates/config" "$HOME/.atst/config"
  old=$(cfg_dump)
  cfg_strict_from_template "$HOME/.atst/config"
  new=$(cfg_dump)
  [ "$(printf '%s\n' "$old" | head -n 1)" = "fmt=legacy" ]
  [ "$(printf '%s\n' "$new" | head -n 1)" = "fmt=strict" ]
  [[ "$new" == *'declare -x WINEARCH="win32"'* ]]
  [[ "$new" == *'declare -a ATST_TARGETS=([0]="Land Prime")'* ]]
  [ "$(printf '%s\n' "$old" | sed 1d)" = "$(printf '%s\n' "$new" | sed 1d)" ]
}

@test "CFG-12: WINEPREFIX from the environment wins over the default in both forms" {
  local old new
  mkdir -p "$HOME/.atst" "$ATST_TEST_SANDBOX/other"
  cp "$repo/templates/config" "$HOME/.atst/config"
  old=$(cfg_dump WINEPREFIX="$ATST_TEST_SANDBOX/other")
  cfg_strict_from_template "$HOME/.atst/config"
  new=$(cfg_dump WINEPREFIX="$ATST_TEST_SANDBOX/other")
  [[ "$old" == *"declare -x WINEPREFIX=\"$ATST_TEST_SANDBOX/other\""* ]]
  [[ "$new" == *"declare -x WINEPREFIX=\"$ATST_TEST_SANDBOX/other\""* ]]
  [ "$(printf '%s\n' "$old" | sed 1d)" = "$(printf '%s\n' "$new" | sed 1d)" ]
}

@test "CFG-13: a KEY=VALUE config is not run: \$(...) in single quotes stays as text" {
  mkdir -p "$HOME/.atst"
  cfg_strict_from_template "$HOME/.atst/config"
  printf '%s\n' "ATST_X='\$(touch \"\$HOME/marker\")'" >> "$HOME/.atst/config"
  cfg_source 'echo "fmt=$ATST_CONFIG_FORMAT"; printf "x=%s\n" "$ATST_X"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"fmt=strict"* ]]
  [[ "$output" == *'x=$(touch "$HOME/marker")'* ]]
  [ ! -e "$HOME/marker" ]
}

@test "CFG-14: the template as it is is the old form and prints nothing new" {
  mkdir -p "$HOME/.atst"
  cp "$repo/templates/config" "$HOME/.atst/config"
  cfg_source 'echo "targets=${#ATST_TARGETS[@]}"; echo "line_id=${ATST_LINE_ID+set}"; echo "fmt=$ATST_CONFIG_FORMAT"'
  [ "$status" -eq 0 ]
  [ "$(cfg_warn_count)" -eq 0 ]
  [ "$output" = "$(printf '%s\n' after-source targets=1 line_id=set fmt=legacy)" ]
}

@test "CFG-15: one mistyped line in a KEY=VALUE config makes it the old form, read once with one [warn]" {
  local n
  mkdir -p "$HOME/.atst"
  cfg_strict_from_template "$HOME/.atst/config"
  sed -i "s/^ATST_TARGETS=('Land Prime')\$/echo x >> \"\$HOME\/atst_source_count\"\nATST_TARGETS=('A_MT4)/" "$HOME/.atst/config"
  [ "$(grep -c "^ATST_TARGETS=('A_MT4)\$" "$HOME/.atst/config")" -eq 1 ]
  n=$(grep -n '^echo x' "$HOME/.atst/config" | cut -d: -f1)
  cfg_source 'echo "fmt=$ATST_CONFIG_FORMAT line=$ATST_CONFIG_FORMAT_LINE"'
  [ "$status" -eq 0 ]
  [ "$(cfg_warn_count)" -eq 1 ]
  [[ "$output" == *"fmt=legacy line=$n"* ]]
  [ "$(wc -l < "$HOME/atst_source_count")" -eq 1 ]
}

@test "CFG-16: a mistyped ATST_TARGETS in a KEY=VALUE config still reaches LINE as RUNNER_TARGETS_EMPTY" {
  local home n
  home=$(atst_test_make_runner_home)
  for n in check_reboot check_order check_process check_monitoring check_tick check_ping check_price check_spread heartbeat; do
    atst_test_stub_script "$home" "$n.sh" record
  done
  mkdir -p "$HOME/.atst"
  cfg_strict_from_template "$HOME/.atst/config"
  sed -i "s/^ATST_TARGETS=('Land Prime')\$/ATST_TARGETS=('A_MT4)/" "$HOME/.atst/config"
  sed -i 's/^ATST_CHECK_TIMEOUT=.*/ATST_CHECK_TIMEOUT=2/; s/^ATST_ORDER_CHECK_INTERVAL=.*/ATST_ORDER_CHECK_INTERVAL=0/' "$HOME/.atst/config"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -cF '[warn] ~/.atst/config may not have been read completely' "$HOME/.atst/log/check_all.log")" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^RUNNER_TARGETS_EMPTY,1,' "$HOME/.atst/alert_status")" -eq 1 ]
}

@test "CFG-17: doctor shows a KEY=VALUE config on one config line" {
  mkdir -p "$HOME/.atst"
  cfg_strict_from_template "$HOME/.atst/config"
  run bash "$repo/doctor.sh"
  [ "$(printf '%s\n' "$output" | grep -c '^OK config ')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^OK config KEY=VALUE 形式')" -eq 1 ]
}

@test "CFG-18: doctor shows the template as the old form with the first line and key out of the form" {
  local n
  mkdir -p "$HOME/.atst"
  cp "$repo/templates/config" "$HOME/.atst/config"
  n=$(grep -n '^ATST_CONFIG_DIR=' "$repo/templates/config" | cut -d: -f1)
  run bash "$repo/doctor.sh"
  [ "$(printf '%s\n' "$output" | grep -c '^OK config ')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c "^OK config 旧形式 .* $n 行目 (ATST_CONFIG_DIR)")" -eq 1 ]
}

@test "CFG-19: doctor names the key of the line out of the form but never its value" {
  local n
  mkdir -p "$HOME/.atst"
  cfg_strict_from_template "$HOME/.atst/config"
  echo 'ATST_HEARTBEAT_URL=https://h/?k=secret-value' >> "$HOME/.atst/config"
  n=$(wc -l < "$HOME/.atst/config")
  run bash "$repo/doctor.sh"
  [ "$(printf '%s\n' "$output" | grep -c "^OK config 旧形式 .* $n 行目 (ATST_HEARTBEAT_URL)")" -eq 1 ]
  [[ "$output" != *secret-value* ]]
}

@test "CFG-20: the parser runs with no PATH (builtins only)" {
  cfg_strict_from_template "$F"
  run bash -c '. "$1" >/dev/null 2>&1; PATH=""; atst_config_parse "$2"' _ "$repo/common.sh" "$F"
  [ "$status" -eq 0 ]
}
