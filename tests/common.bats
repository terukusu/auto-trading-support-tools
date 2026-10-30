#!/usr/bin/env bats
# Fixture check: common.sh can be read inside the sandbox (not a regression test).

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

# Prints the index of the MT named $1 (mt_name is upper case).
mt_index_of() {
  local i
  for i in "${!mt_name[@]}"; do
    if [ "${mt_name[$i]}" = "$1" ]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

@test "common.sh creates config under the sandbox HOME" {
  atst_test_source_common || return 1
  [ "$HOME" = "$ATST_TEST_SANDBOX/home" ]
  [ -f "$HOME/.atst/config" ]
}

@test "mt_home has as many entries as the MTs made" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt B_MT5 MT5 0123456789ABCDEF0123456789ABCDEF
  atst_test_source_common || return 1
  [ "${#mt_home[@]}" -eq 2 ]
}

@test "mt_data points to AppData when origin.txt exists" {
  local hash=0123456789ABCDEF0123456789ABCDEF idx
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt B_MT5 MT5 "$hash"
  atst_test_source_common || return 1
  idx=$(mt_index_of B_MT5)
  [ -n "$idx" ]
  [ "${mt_type[$idx]}" = MT5 ]
  [ "${mt_data[$idx]}" = "$WINEPREFIX/drive_c/users/tester/AppData/Roaming/MetaQuotes/Terminal/$hash" ]
}

@test "mt_data points to the install folder without origin.txt" {
  local idx
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt B_MT5 MT5 0123456789ABCDEF0123456789ABCDEF
  atst_test_source_common || return 1
  idx=$(mt_index_of A_MT4)
  [ -n "$idx" ]
  [ "${mt_type[$idx]}" = MT4 ]
  [ "${mt_data[$idx]}" = "$WINEPREFIX/drive_c/Program Files/A_MT4" ]
}

@test "atst_log prints its arguments after the timestamp" {
  atst_test_source_common || return 1
  run atst_log "a b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"] a b" ]]
}

@test "HT-01: atst_has_targets is true only for at least one element and no empty one (#95)" {
  local i expected=(1 1 1 1 0 0 0)
  atst_test_source_common || return 1
  for i in 0 1 2 3 4 5 6; do
    unset ATST_TARGETS
    case "$i" in
      0) ;;
      1) ATST_TARGETS=() ;;
      2) ATST_TARGETS=('') ;;
      3) ATST_TARGETS=('a' '') ;;
      4) ATST_TARGETS=('a') ;;
      5) ATST_TARGETS='Land Prime' ;;
      6) ATST_TARGETS=([1]=a) ;;
    esac
    run atst_has_targets
    [ "$status" -eq "${expected[$i]}" ] || { echo "case $i: status=$status"; false; }
    [ -z "$output" ]
  done
}

@test "D6-01: ATST_TARGETS, ATST_CHECK_TIMEOUT, ATST_ORDER_CHECK_INTERVAL and ATST_ALERT_REMIND_MINUTES come from the config only" {
  mkdir -p "$HOME/.atst"
  cp "$BATS_TEST_DIRNAME/../templates/config" "$HOME/.atst/config"
  sed -i -e '/^ATST_TARGETS=/d' -e '/^ATST_CHECK_TIMEOUT=/d' -e '/^ATST_ORDER_CHECK_INTERVAL=/d' \
    -e '/^ATST_ALERT_REMIND_MINUTES=/d' "$HOME/.atst/config"
  export ATST_TARGETS=X ATST_CHECK_TIMEOUT=7 ATST_ORDER_CHECK_INTERVAL=7 ATST_ALERT_REMIND_MINUTES=7
  atst_test_source_common || return 1
  [ -z "${ATST_TARGETS+x}" ]
  [ -z "${ATST_CHECK_TIMEOUT+x}" ]
  [ -z "${ATST_ORDER_CHECK_INTERVAL+x}" ]
  [ -z "${ATST_ALERT_REMIND_MINUTES+x}" ]
  run atst_has_targets
  [ "$status" -eq 1 ]
}

# cf_break_threshold <line>
# Puts templates/config in the sandbox HOME with the ATST_MONITORING_THRESHOLD=180 line replaced by
# <line>. Fails unless that line is exactly one and comes before ATST_LINE_ID and ATST_TARGETS, so a
# change of the template cannot make the tests below pass for nothing.
cf_break_threshold() {
  local cfg="$HOME/.atst/config" n line_no line_id_no targets_no
  mkdir -p "$HOME/.atst" || return 1
  cp "$BATS_TEST_DIRNAME/../templates/config" "$cfg" || return 1
  n=$(grep -c '^ATST_MONITORING_THRESHOLD=180$' "$cfg")
  [ "$n" -eq 1 ] || return 1
  sed -i "s|^ATST_MONITORING_THRESHOLD=180\$|$1|" "$cfg" || return 1
  n=$(grep -cxF -- "$1" "$cfg")
  [ "$n" -eq 1 ] || return 1
  line_no=$(grep -nxF -- "$1" "$cfg" | cut -d: -f1)
  line_id_no=$(grep -n '^ATST_LINE_ID=' "$cfg" | head -n 1 | cut -d: -f1)
  targets_no=$(grep -n '^ATST_TARGETS=' "$cfg" | head -n 1 | cut -d: -f1)
  [ -n "$line_no" ] && [ -n "$line_id_no" ] && [ -n "$targets_no" ] || return 1
  [ "$line_no" -lt "$line_id_no" ] && [ "$line_no" -lt "$targets_no" ]
}

# cf_source <code>
# Sources common.sh in a new bash (no ERR trap, no set -e, as cron starts the scripts) and runs <code>
# after it. LC_ALL=C fixes bash's own messages to English.
cf_source() {
  run env LC_ALL=C bash -c '. "$1" || exit 9; echo after-source; '"$1" _ "$BATS_TEST_DIRNAME/../common.sh"
}

# Prints how many [warn] lines about the config $output has.
cf_warn_count() {
  printf '%s\n' "$output" | grep -c '^\[warn\] ~/.atst/config may not have been read completely'
}

# Settings a config that was read to the end has (only whether they are set, never their values).
CF_AFTER_CODE='echo "targets=${#ATST_TARGETS[@]}"; echo "line_id=${ATST_LINE_ID+set}"'

@test "CF-01: a parse error in a middle line warns once and the lines after it are not read (#114)" {
  cf_break_threshold 'ATST_MONITORING_THRESHOLD=(180' || return 1
  cf_source 'echo "targets=[${ATST_TARGETS+set}]"'
  [ "$status" -eq 0 ]
  [ "$(cf_warn_count)" -eq 1 ]
  [[ "$output" == *"targets=[]"* ]]
  [[ "$output" == *after-source* ]]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "CF-02: a middle line failing with a space after = warns once and the rest is read (#114)" {
  cf_break_threshold 'ATST_MONITORING_THRESHOLD= 180' || return 1
  cf_source "$CF_AFTER_CODE"
  [ "$status" -eq 0 ]
  [ "$(cf_warn_count)" -eq 1 ]
  [[ "$output" == *"command not found"* ]]
  [[ "$output" == *"targets=1"* ]]
  [[ "$output" == *"line_id=set"* ]]
  [[ "$output" == *after-source* ]]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "CF-03: a middle line with a failing command substitution warns once and the rest is read (#114)" {
  cf_break_threshold 'ATST_MONITORING_THRESHOLD=$(atst_test_no_such_command_zz)' || return 1
  cf_source "$CF_AFTER_CODE"
  [ "$status" -eq 0 ]
  [ "$(cf_warn_count)" -eq 1 ]
  [[ "$output" == *"command not found"* ]]
  [[ "$output" == *"targets=1"* ]]
  [[ "$output" == *"line_id=set"* ]]
  [[ "$output" == *after-source* ]]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "CF-04: the template config as it is gives no warning (#114)" {
  mkdir -p "$HOME/.atst"
  cp "$BATS_TEST_DIRNAME/../templates/config" "$HOME/.atst/config"
  cf_source "$CF_AFTER_CODE"
  [ "$status" -eq 0 ]
  [ "$(cf_warn_count)" -eq 0 ]
  [[ "$output" == *"targets=1"* ]]
  [[ "$output" == *after-source* ]]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "CF-05: a config with a failing line is run only once (#114)" {
  cf_break_threshold 'ATST_MONITORING_THRESHOLD= 180' || return 1
  echo 'echo x >> "$HOME/atst_source_count"' >> "$HOME/.atst/config"
  cf_source ':'
  [ "$status" -eq 0 ]
  [ "$(cf_warn_count)" -eq 1 ]
  [ "$(wc -l < "$HOME/atst_source_count")" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "CF-06: no ERR trap, set -e or work variable is left in the caller after the source (#114)" {
  local flags_line
  cf_break_threshold 'ATST_MONITORING_THRESHOLD= 180' || return 1
  cf_source 'echo "trap=[$(trap -p ERR)]"; echo "flags=$-"; echo "vars=[${_atst_cfg_failed+set}${_atst_cfg_errexit+set}]"'
  [ "$status" -eq 0 ]
  [ "$(cf_warn_count)" -eq 1 ]
  [[ "$output" == *"trap=[]"* ]]
  [[ "$output" == *"vars=[]"* ]]
  flags_line=$(printf '%s\n' "$output" | grep '^flags=')
  [ -n "$flags_line" ]
  [[ "$flags_line" != *e* ]]
  # A caller with set -e is not stopped by the failing line and gets set -e back.
  run env LC_ALL=C bash -c 'set -e; . "$1"; echo after-source; echo "flags=$-"; echo "vars=[${_atst_cfg_failed+set}${_atst_cfg_errexit+set}]"' _ "$BATS_TEST_DIRNAME/../common.sh"
  [ "$status" -eq 0 ]
  [ "$(cf_warn_count)" -eq 1 ]
  [[ "$output" == *after-source* ]]
  flags_line=$(printf '%s\n' "$output" | grep '^flags=')
  [[ "$flags_line" == flags=*e* ]]
  [[ "$output" == *"vars=[]"* ]]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "CF-07: sourcing common.sh in the test body keeps the ERR trap and flags of bats (#114)" {
  local before flags
  before=$(trap -p ERR)
  flags=$-
  [ -n "$before" ]
  atst_test_source_common || return 1
  [ "$(trap -p ERR)" = "$before" ]
  [ "$-" = "$flags" ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "MK-1: atst_mask_tail4 shows **** and the last 4 characters of 8 or more (#136)" {
  atst_test_source_common
  [ "$(atst_mask_tail4 abcdefgh)" = '****efgh' ]
  [ "$(atst_mask_tail4 https://example.invalid/ping/abcd9876)" = '****9876' ]
}

@test "MK-2: atst_mask_tail4 shows only **** for fewer than 8 characters or an empty value (#136)" {
  atst_test_source_common
  [ "$(atst_mask_tail4 abcdefg)" = '****' ]
  [ "$(atst_mask_tail4 '')" = '****' ]
}

@test "MK-3: atst_mask_tail4 prints no newline and returns 0 (#136)" {
  local out
  atst_test_source_common
  out=$(atst_mask_tail4 abcdefgh; echo x)
  [ "$out" = '****efghx' ]
  run atst_mask_tail4 abcdefgh
  [ "$status" -eq 0 ]
}

# #133: StartUp ini helpers of mtctl.sh start (ATST_AUTO_ATTACH_EA).

@test "IN-1: atst_auto_attach_enabled is true only for exactly 1" {
  local v
  atst_test_source_common || return 1
  ATST_AUTO_ATTACH_EA=1
  run atst_auto_attach_enabled
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  for v in 0 "" yes 01 " 1" "1 "; do
    ATST_AUTO_ATTACH_EA=$v
    run atst_auto_attach_enabled
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
  done
  unset ATST_AUTO_ATTACH_EA
  run atst_auto_attach_enabled
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "IN-2: atst_startup_ini_path is drive_c/atst/startup_<lower name with _>.ini in WINEPREFIX" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common || return 1
  run atst_startup_ini_path A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "$WINEPREFIX/drive_c/atst/startup_a_mt4.ini" ]
  run atst_startup_ini_path "Land Prime"
  [ "$status" -eq 0 ]
  [ "$output" = "$WINEPREFIX/drive_c/atst/startup_land_prime.ini" ]
  run atst_startup_ini_path A-MT.4
  [ "$status" -eq 0 ]
  [ "$output" = "$WINEPREFIX/drive_c/atst/startup_a_mt_4.ini" ]
  [[ $output != *"$HOME/.atst"* ]]
  # a trailing / of WINEPREFIX gives the same logical path
  WINEPREFIX="$WINEPREFIX/"
  run atst_startup_ini_path A_MT4
  [ "$output" = "${WINEPREFIX%/}/drive_c/atst/startup_a_mt4.ini" ]
  # nothing is created
  [ ! -e "${WINEPREFIX%/}/drive_c/atst" ]
}

@test "IN-3: atst_startup_ini_path prints nothing and returns 1 for an empty name or no WINEPREFIX" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common || return 1
  run atst_startup_ini_path ""
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  WINEPREFIX=""
  run atst_startup_ini_path A_MT4
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  WINEPREFIX="$ATST_TEST_SANDBOX/no-such-prefix"
  run atst_startup_ini_path A_MT4
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  run atst_startup_ini_win_path A_MT4
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "IN-4: atst_startup_ini_content MT4 prints 5 fixed CRLF lines and nothing secret, the same bytes twice" {
  local f="$ATST_TEST_SANDBOX/a.ini" f2="$ATST_TEST_SANDBOX/b.ini" rc
  atst_test_source_common || return 1
  atst_startup_ini_content MT4 EURUSD M5 > "$f"
  rc=$?
  [ "$rc" -eq 0 ]
  atst_startup_ini_content MT4 EURUSD M5 > "$f2"
  [ "$(grep -c $'\r$' "$f")" -eq 5 ]
  [ "$(wc -l < "$f")" -eq 5 ]
  [ "$(tail -c 2 "$f" | od -An -tx1 | tr -d ' ')" = "0d0a" ]
  [ "$(head -c 1 "$f")" = ";" ]
  [ "$(tr -d '\r' < "$f")" = "; generated by atst mtctl.sh start (ATST_AUTO_ATTACH_EA=1). overwritten on every start.
[StartUp]
Symbol=EURUSD
Period=M5
Expert=TerminalMonitoring" ]
  [ "$(tr -d '\r' < "$f" | LC_ALL=C grep -c '[^[:print:]]')" -eq 0 ]
  [ "$(grep -ciE 'login|password|server|^\[common\]|^\[experts\]|^\[charts\]|^template=|^expertparameters=' "$f")" -eq 0 ]
  cmp -s "$f" "$f2"
}

@test "IN-5: atst_startup_ini_content MT5 uses Advisors\\TerminalMonitoring" {
  local f="$ATST_TEST_SANDBOX/a.ini"
  atst_test_source_common || return 1
  atst_startup_ini_content MT5 EURUSD M5 > "$f"
  [ "$(tr -d '\r' < "$f" | sed -n 5p)" = 'Expert=Advisors\TerminalMonitoring' ]
  [ "$(tr -d '\r' < "$f" | sed -n 1,4p)" = "; generated by atst mtctl.sh start (ATST_AUTO_ATTACH_EA=1). overwritten on every start.
[StartUp]
Symbol=EURUSD
Period=M5" ]
}

@test "IN-6: a wrong symbol returns 2 and prints nothing; the allowed characters return 0" {
  local v
  atst_test_source_common || return 1
  for v in 'EURUSD;Login=1' '' "$(printf 'A%.0s' $(seq 1 33))" $'EUR\nUSD' $'EURUSD\n' 'EUR USD' $'EUR\tUSD' 'EUR=USD' 'EUR[1]'; do
    run atst_startup_ini_content MT4 "$v" M5
    [ "$status" -eq 2 ]
    [ "$output" = "" ]
  done
  for v in "$(printf 'A%.0s' $(seq 1 32))" EURUSD.m '#US30' 'XAU&USD!@-_'; do
    run atst_startup_ini_content MT4 "$v" M5
    [ "$status" -eq 0 ]
    [ "${lines[2]%$'\r'}" = "Symbol=$v" ]
  done
}

@test "IN-7: a wrong period returns 3 and prints nothing; the 9 periods return 0" {
  local p
  atst_test_source_common || return 1
  for p in M2 MN1 m5 "" "M5 " "H1;"; do
    run atst_startup_ini_content MT4 EURUSD "$p"
    [ "$status" -eq 3 ]
    [ "$output" = "" ]
  done
  for p in M1 M5 M15 M30 H1 H4 D1 W1 MN; do
    run atst_startup_ini_content MT4 EURUSD "$p"
    [ "$status" -eq 0 ]
    [ "${lines[3]%$'\r'}" = "Period=$p" ]
  done
}

@test "IN-8: a wrong type returns 4; the symbol is checked first, then the period" {
  local t
  atst_test_source_common || return 1
  for t in MT6 "" mt4; do
    run atst_startup_ini_content "$t" EURUSD M5
    [ "$status" -eq 4 ]
    [ "$output" = "" ]
  done
  run atst_startup_ini_content MT6 'a;b' M2
  [ "$status" -eq 2 ]
  run atst_startup_ini_content MT6 EURUSD M2
  [ "$status" -eq 3 ]
}

@test "IN-9: the ini path in Windows form is C:\\atst\\startup_<n>.ini (no Z:, no winepath)" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common || return 1
  run atst_to_win_path "$(atst_startup_ini_path A_MT4)" "$(cd "$WINEPREFIX" && pwd)"
  [ "$output" = 'C:\atst\startup_a_mt4.ini' ]
  run atst_to_win_path "$(atst_startup_ini_path "Land Prime")" "$(cd "$WINEPREFIX" && pwd)"
  [ "$output" = 'C:\atst\startup_land_prime.ini' ]
  run atst_startup_ini_win_path A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = 'C:\atst\startup_a_mt4.ini' ]
  [[ $output != *Z:* ]]
}

@test "IN-10: atst_startup_ini_arg is the bare path for MT4 and /config:<path> for MT5 (real host, #133)" {
  atst_test_source_common || return 1
  run atst_startup_ini_arg MT4 'C:\atst\startup_a_mt4.ini'
  [ "$status" -eq 0 ]
  [ "$output" = 'C:\atst\startup_a_mt4.ini' ]
  run atst_startup_ini_arg MT5 'C:\atst\startup_b_mt5.ini'
  [ "$status" -eq 0 ]
  [ "$output" = '/config:C:\atst\startup_b_mt5.ini' ]
  run atst_startup_ini_arg MT6 'C:\atst\x.ini'
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  run atst_startup_ini_arg MT4 ''
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}
