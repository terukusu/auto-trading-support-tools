#!/usr/bin/env bats
# mtctl.sh: exit status and output of list / status / stop on the sandbox (#101, #132). start runs wine only
# as the record stub of the sandbox (WINE=<sandbox>/wine, calls.log), never the real Wine (#133).

load test_helper

setup() {
  atst_test_setup_sandbox
  atst_test_make_mt A_MT4 MT4
}

teardown() {
  atst_test_teardown_sandbox
}

@test "MC-1: list with one MetaTrader exits 0" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1 MetaTrader found. (WINEPREFIX=$WINEPREFIX)" ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[1]}" == *"name=A_MT4"* ]]
}

@test "MC-2: status of one stopped MetaTrader exits 0" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" status A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "status=stopped, pid= -, name=A_MT4 (WINEPREFIX=$WINEPREFIX)" ]
}

@test "MC-3: status without a name prints usage and exits 1" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" status
  [ "$status" -eq 1 ]
}

@test "MC-4: stop of a MetaTrader that is not running exits 0" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" stop A_MT4
  [ "$status" -eq 0 ]
}

@test "MC-5: stop of a MetaTrader that is not running shows the WINEPREFIX in use (#132)" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" stop A_MT4
  [ "$status" -eq 0 ]
  [[ "$output" == *"(WINEPREFIX=$WINEPREFIX)"* ]]
}

@test "MC-6: stop with -q prints nothing" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" -q stop A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "MC-7: start of a MetaTrader that is not found shows the WINEPREFIX in use" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start NO_SUCH_MT
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_SUCH_MT (WINEPREFIX=$WINEPREFIX)"* ]]
}

# --- start with ATST_AUTO_ATTACH_EA (#133) ---

# Points WINE at the record stub (calls.log); never the real Wine.
mc_stub_wine() {
  atst_test_stub_script "$ATST_TEST_SANDBOX" wine record || return 1
  WINE="$ATST_TEST_SANDBOX/wine"
  export WINE
}

# mc_enable [<symbol> [<period>]]
mc_enable() {
  atst_test_set_config ATST_AUTO_ATTACH_EA 1 || return 1
  atst_test_set_config ATST_AUTO_ATTACH_SYMBOL "${1-EURUSD}" || return 1
  atst_test_set_config ATST_AUTO_ATTACH_PERIOD "${2-M5}"
}

# The wine calls without the epoch, one per line.
mc_wine_lines() {
  grep '^wine ' "$ATST_TEST_SANDBOX/calls.log" 2>/dev/null | cut -d' ' -f3-
}

# The arguments of wine start without /config: (the order mtctl.sh has always used).
mc_base_args() {
  printf '[start] [/b] [/d] [%s] [/unix] [%s]' "C:\\Program Files\\$1" "$WINEPREFIX/drive_c/Program Files/$1/terminal.exe"
}

mc_stderr_of_start() {
  run bash -c 'bash "$0" "$@" 2>&1 1>/dev/null' "$BATS_TEST_DIRNAME/../mtctl.sh" "$@"
}

@test "MC-8: start with ATST_AUTO_ATTACH_EA=1 writes the ini (600 in a 700 dir) and passes /config:C:\\atst\\..." {
  local atstdir="$WINEPREFIX/drive_c/atst" ini="$WINEPREFIX/drive_c/atst/startup_a_mt4.ini"
  mc_stub_wine
  mc_enable
  [ ! -e "$atstdir" ]
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "executing: $WINEPREFIX/drive_c/Program Files/A_MT4/terminal.exe" ]
  [ "$(stat -c %a "$atstdir")" = 700 ]
  [ "$(stat -c %a "$ini")" = 600 ]
  [ -z "$(ls "$HOME"/.atst/startup_* 2>/dev/null)" ]
  [ "$(mc_wine_lines | wc -l)" -eq 1 ]
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4) [/config:C:\\atst\\startup_a_mt4.ini]" ]
  [ "$(mc_wine_lines | grep -o '\[/config:' | wc -l)" -eq 1 ]
  [ "$(grep -c '^auto_attach: ' "$HOME/.atst/wine_a_mt4.log")" -eq 1 ]
  [ "$(grep -n '^auto_attach: ' "$HOME/.atst/wine_a_mt4.log" | cut -d: -f1)" -gt "$(grep -n '^===== START' "$HOME/.atst/wine_a_mt4.log" | cut -d: -f1)" ]
  grep -qxF 'auto_attach: /config:C:\atst\startup_a_mt4.ini' "$HOME/.atst/wine_a_mt4.log"
  # MC-15: nothing goes through Z:
  [ "$(grep -c 'Z:' "$ATST_TEST_SANDBOX/calls.log")" -eq 0 ]
  [ "$(grep -c '^auto_attach: .*Z:' "$HOME/.atst/wine_a_mt4.log")" -eq 0 ]
}

@test "MC-9: ATST_AUTO_ATTACH_EA=0, no EA line and an old config without the 3 lines start as before" {
  local c
  mc_stub_wine
  atst_test_set_config ATST_AUTO_ATTACH_SYMBOL EURUSD
  for c in zero noline old; do
    case $c in
      zero) atst_test_set_config ATST_AUTO_ATTACH_EA 0 ;;
      noline) sed -i '/^ATST_AUTO_ATTACH_EA=/d' "$HOME/.atst/config" ;;
      old) sed -i '/^ATST_AUTO_ATTACH_/d' "$HOME/.atst/config" ;;
    esac
    rm -f "$ATST_TEST_SANDBOX/calls.log"
    run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start A_MT4
    [ "$status" -eq 0 ]
    [ "$output" = "executing: $WINEPREFIX/drive_c/Program Files/A_MT4/terminal.exe" ]
    [ ! -e "$WINEPREFIX/drive_c/atst" ]
    [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4)" ]
    [ "$(grep -c 'auto_attach' "$HOME/.atst/wine_a_mt4.log")" -eq 0 ]
  done
  [ "$(grep -c '^ATST_AUTO_ATTACH_' "$HOME/.atst/config")" -eq 0 ]
}

@test "MC-9b: with ATST_AUTO_ATTACH_EA=0 an existing ini and its dir are neither read, changed nor removed" {
  local atstdir="$WINEPREFIX/drive_c/atst" ini="$WINEPREFIX/drive_c/atst/startup_a_mt4.ini"
  mc_stub_wine
  atst_test_set_config ATST_AUTO_ATTACH_EA 0
  mkdir -p "$atstdir"
  chmod 755 "$atstdir"
  printf 'x\n' > "$ini"
  chmod 644 "$ini"
  cp -p "$ini" "$ATST_TEST_SANDBOX/ref"
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start A_MT4
  [ "$status" -eq 0 ]
  cmp -s "$ini" "$ATST_TEST_SANDBOX/ref"
  [ "$(stat -c %a "$ini")" = 644 ]
  [ "$(stat -c %a "$atstdir")" = 755 ]
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4)" ]
}

@test "MC-10: the ini written by start is the 5 CRLF lines of atst_startup_ini_content and nothing secret" {
  local ini="$WINEPREFIX/drive_c/atst/startup_a_mt4.ini"
  mc_stub_wine
  mc_enable
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start A_MT4
  [ "$status" -eq 0 ]
  [ "$(grep -c $'\r$' "$ini")" -eq 5 ]
  [ "$(wc -l < "$ini")" -eq 5 ]
  [ "$(head -c 1 "$ini")" = ";" ]
  [ "$(tr -d '\r' < "$ini" | sed -n 2,5p)" = "[StartUp]
Symbol=EURUSD
Period=M5
Expert=TerminalMonitoring" ]
  [ "$(tr -d '\r' < "$ini" | grep -v '^$' | wc -l)" -eq 5 ]
  [ "$(grep -ciE 'login|password|server|\[common\]|\[experts\]' "$ini")" -eq 0 ]
  atst_test_source_common || return 1
  cmp -s "$ini" <(atst_startup_ini_content MT4 EURUSD M5)
}

@test "MC-11: start twice gives the same ini; 644 / 755 go back to 600 / 700 and no temporary file is left" {
  local atstdir="$WINEPREFIX/drive_c/atst" ini="$WINEPREFIX/drive_c/atst/startup_a_mt4.ini"
  mc_stub_wine
  mc_enable
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start A_MT4
  [ "$status" -eq 0 ]
  cp "$ini" "$ATST_TEST_SANDBOX/ref"
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start A_MT4
  [ "$status" -eq 0 ]
  cmp -s "$ini" "$ATST_TEST_SANDBOX/ref"
  [ "$(stat -c %a "$ini")" = 600 ]
  chmod 644 "$ini"
  chmod 755 "$atstdir"
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start A_MT4
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$ini")" = 600 ]
  [ "$(stat -c %a "$atstdir")" = 700 ]
  cmp -s "$ini" "$ATST_TEST_SANDBOX/ref"
  [ "$(ls -A "$atstdir")" = "startup_a_mt4.ini" ]
}

@test "MC-12: an MT5 ini has Expert=Advisors\\TerminalMonitoring and its own /config:" {
  mc_stub_wine
  atst_test_make_mt B_MT5 MT5
  mc_enable
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start B_MT5
  [ "$status" -eq 0 ]
  [ "$(tr -d '\r' < "$WINEPREFIX/drive_c/atst/startup_b_mt5.ini" | sed -n 5p)" = 'Expert=Advisors\TerminalMonitoring' ]
  [ "$(mc_wine_lines)" = "$(mc_base_args B_MT5) [/config:C:\\atst\\startup_b_mt5.ini]" ]
  [ "$(grep -c 'Z:' "$ATST_TEST_SANDBOX/calls.log")" -eq 0 ]
}

@test "MC-13: a wrong or empty symbol / period starts without /config:, one stderr line without the value, -q silent" {
  local c log="$HOME/.atst/wine_a_mt4.log"
  mc_stub_wine
  for c in bad empty noperiod; do
    case $c in
      bad) mc_enable 'EURUSD;Login=1' M5 ;;
      empty) mc_enable '' M5 ;;
      noperiod) mc_enable EURUSD '' ;;
    esac
    rm -f "$ATST_TEST_SANDBOX/calls.log" "$log"
    mc_stderr_of_start start A_MT4
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ ${lines[0]} == *A_MT4* ]]
    if [ "$c" = noperiod ]; then
      [[ ${lines[0]} == *"ATST_AUTO_ATTACH_PERIOD is empty or invalid"* ]]
    else
      [[ ${lines[0]} == *"ATST_AUTO_ATTACH_SYMBOL is empty or invalid"* ]]
    fi
    [[ $output != *Login* ]]
    [ "$(grep -c Login "$log")" -eq 0 ]
    [ ! -e "$WINEPREFIX/drive_c/atst/startup_a_mt4.ini" ]
    [ "$(mc_wine_lines | wc -l)" -eq 1 ]
    [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4)" ]
    [ "$(grep -c '^auto_attach: skipped (' "$log")" -eq 1 ]

    rm -f "$ATST_TEST_SANDBOX/calls.log"
    run bash "$BATS_TEST_DIRNAME/../mtctl.sh" -q start A_MT4
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(mc_wine_lines | wc -l)" -eq 1 ]
  done
}

@test "MC-14: an ini that cannot be written starts without /config:, leaves no temporary file and keeps the file in the way" {
  local atstdir="$WINEPREFIX/drive_c/atst" log="$HOME/.atst/wine_a_mt4.log"
  mc_stub_wine
  mc_enable
  mkdir -p "$WINEPREFIX/drive_c"
  : > "$atstdir"
  mc_stderr_of_start start A_MT4
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == *"cannot write"* ]]
  [[ ${lines[0]} == *startup_a_mt4.ini* ]]
  [[ $output != *"$HOME"* ]]
  [[ $output != *"$WINEPREFIX"* ]]
  [ -f "$atstdir" ]
  [ -z "$(find "$ATST_TEST_SANDBOX" -name '.startup.*')" ]
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4)" ]
  [ "$(grep -c '^auto_attach: skipped (cannot write' "$log")" -eq 1 ]

  # a symlink in place of drive_c/atst is not followed
  rm -f "$atstdir" "$ATST_TEST_SANDBOX/calls.log"
  mkdir -p "$ATST_TEST_SANDBOX/elsewhere"
  ln -s "$ATST_TEST_SANDBOX/elsewhere" "$atstdir"
  mc_stderr_of_start start A_MT4
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == *"cannot write"* ]]
  [ -z "$(ls -A "$ATST_TEST_SANDBOX/elsewhere")" ]
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4)" ]
}

@test "MC-14b: the ini path is not converted by winepath" {
  mc_stub_wine
  mc_enable
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  printf '#!/bin/bash\ncase "${!#}" in *.ini) exit 1 ;; esac\nexec %q "$@"\n' "$BATS_TEST_DIRNAME/stubs/winepath" \
    > "$ATST_TEST_SANDBOX/bin/winepath"
  chmod 755 "$ATST_TEST_SANDBOX/bin/winepath"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" start A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "executing: $WINEPREFIX/drive_c/Program Files/A_MT4/terminal.exe" ]
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4) [/config:C:\\atst\\startup_a_mt4.ini]" ]
}

@test "MC-14c: a blank in WINEPREFIX does not reach /config:" {
  WINEPREFIX="$ATST_TEST_SANDBOX/pre fix"
  export WINEPREFIX
  atst_test_make_mt A_MT4 MT4
  mc_stub_wine
  mc_enable
  mc_stderr_of_start start A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(stat -c %a "$WINEPREFIX/drive_c/atst/startup_a_mt4.ini")" = 600 ]
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4) [/config:C:\\atst\\startup_a_mt4.ini]" ]
  [ "$(grep -c 'Z:' "$ATST_TEST_SANDBOX/calls.log")" -eq 0 ]
}
