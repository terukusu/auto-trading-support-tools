#!/usr/bin/env bats
# mtctl.sh: exit status and output of list / status / stop on the sandbox (#101, #132). start runs wine only
# as the record stub of the sandbox (WINE=<sandbox>/wine, calls.log), never the real Wine (#133).
# MC-15..28 (#140): the X wait that does not wait, the MT lock and its stamp, restart of a stopped MT,
# setsid. The waits and the restarts of real processes are in tests/slow/mtctl.bats.

load test_helper

setup() {
  atst_test_setup_sandbox
  atst_test_make_mt A_MT4 MT4
  # #140: never the real /tmp/.X11-unix of the host; MC-1..14c do not wait for X.
  mkdir -p "$ATST_TEST_SANDBOX/x11"
  ATST_X11_DIR="$ATST_TEST_SANDBOX/x11"
  ATST_X_WAIT=0
  export ATST_X11_DIR ATST_X_WAIT
}

teardown() {
  local f pid
  for f in holder.pid child.pid; do
    pid=$(cat "$ATST_TEST_SANDBOX/$f" 2>/dev/null)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) kill "$pid" 2>/dev/null ;;
    esac
  done
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

# The arguments of wine start without the StartUp ini (the order mtctl.sh has always used).
mc_base_args() {
  printf '[start] [/b] [/d] [%s] [/unix] [%s]' "C:\\Program Files\\$1" "$WINEPREFIX/drive_c/Program Files/$1/terminal.exe"
}

mc_stderr_of_start() {
  run bash -c 'bash "$0" "$@" 2>&1 1>/dev/null' "$BATS_TEST_DIRNAME/../mtctl.sh" "$@"
}

@test "MC-8: start with ATST_AUTO_ATTACH_EA=1 writes the ini (600 in a 700 dir) and passes the bare C:\\atst\\... to MT4" {
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
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4) [C:\\atst\\startup_a_mt4.ini]" ]
  [ "$(mc_wine_lines | grep -o '\[C:\\atst\\' | wc -l)" -eq 1 ]
  # MT4 ignores /config: (real host, #133): it is not passed
  [ "$(grep -c '/config:' "$ATST_TEST_SANDBOX/calls.log")" -eq 0 ]
  [ "$(grep -c '^auto_attach: ' "$HOME/.atst/wine_a_mt4.log")" -eq 1 ]
  [ "$(grep -n '^auto_attach: ' "$HOME/.atst/wine_a_mt4.log" | cut -d: -f1)" -gt "$(grep -n '^===== START' "$HOME/.atst/wine_a_mt4.log" | cut -d: -f1)" ]
  grep -qxF 'auto_attach: C:\atst\startup_a_mt4.ini' "$HOME/.atst/wine_a_mt4.log"
  [ "$(grep -c '/config:' "$HOME/.atst/wine_a_mt4.log")" -eq 0 ]
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
  grep -qxF 'auto_attach: /config:C:\atst\startup_b_mt5.ini' "$HOME/.atst/wine_b_mt5.log"
}

@test "MC-13: a wrong or empty symbol / period starts without the ini, one stderr line without the value, -q silent" {
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

@test "MC-14: an ini that cannot be written starts without the ini, leaves no temporary file and keeps the file in the way" {
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
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4) [C:\\atst\\startup_a_mt4.ini]" ]
}

@test "MC-14c: a blank in WINEPREFIX does not reach the ini argument" {
  WINEPREFIX="$ATST_TEST_SANDBOX/pre fix"
  export WINEPREFIX
  atst_test_make_mt A_MT4 MT4
  mc_stub_wine
  mc_enable
  mc_stderr_of_start start A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(stat -c %a "$WINEPREFIX/drive_c/atst/startup_a_mt4.ini")" = 600 ]
  [ "$(mc_wine_lines)" = "$(mc_base_args A_MT4) [C:\\atst\\startup_a_mt4.ini]" ]
  [ "$(grep -c 'Z:' "$ATST_TEST_SANDBOX/calls.log")" -eq 0 ]
}

# --- #140: X wait (no waiting here), MT lock, stamp, restart of a stopped MT, setsid ---

# mc_run_err <mtctl args...>: runs mtctl.sh with stdout in $output and stderr in $E.
mc_run_err() {
  E="$ATST_TEST_SANDBOX/err"
  run bash -c 'f=$1; shift; bash "$@" 2>"$f"' _ "$E" "$BATS_TEST_DIRNAME/../mtctl.sh" "$@"
}

# Milliseconds since $1 (date +%s%N).
mc_ms_since() {
  echo $(( ($(date +%s%N) - $1) / 1000000 ))
}

mc_wine_count() {
  mc_wine_lines | wc -l
}

# mc_wine_body <shell lines>: the wine record stub with <shell lines> run after the record line.
mc_wine_body() {
  mc_stub_wine || return 1
  sed -i '$d' "$ATST_TEST_SANDBOX/wine"
  printf '%s\nexit 0\n' "$1" >> "$ATST_TEST_SANDBOX/wine"
}

# Starts a process holding the lock on $1 (as another mtctl.sh would) and waits until it holds it.
hold_lock() {
  local i
  mkdir -p "$(dirname "$1")" || return 1
  ( exec 8>>"$1"; flock 8; exec sleep 30 ) >/dev/null 2>&1 </dev/null 3>&- &
  echo "$!" > "$ATST_TEST_SANDBOX/holder.pid"
  for i in $(seq 1 20); do
    flock -n "$1" true || return 0
    sleep 0.1
  done
  return 1
}

release_lock() {
  local pid
  pid=$(cat "$ATST_TEST_SANDBOX/holder.pid")
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  rm -f "$ATST_TEST_SANDBOX/holder.pid"
}

@test "MC-15: ATST_X_WAIT=0 does not wait, says nothing and writes x_wait: skipped (ATST_X_WAIT=0)" {
  local t0 ms
  mc_stub_wine
  t0=$(date +%s%N)
  DISPLAY=:1 mc_run_err start A_MT4
  ms=$(mc_ms_since "$t0")
  [ "$status" -eq 0 ]
  [ "$ms" -lt 1000 ]
  [ ! -s "$E" ]
  [ "$(mc_wine_count)" -eq 1 ]
  grep -qxF 'x_wait: skipped (ATST_X_WAIT=0)' "$HOME/.atst/wine_a_mt4.log"
}

@test "MC-16: the socket of :1 / :1.0 / localhost:1 / unix:1 already there gives x_wait: ready (0 s)" {
  local d t0 ms
  mc_stub_wine
  touch "$ATST_X11_DIR/X1"
  for d in :1 :1.0 localhost:1 unix:1; do
    rm -f "$HOME/.atst/wine_a_mt4.log"
    t0=$(date +%s%N)
    DISPLAY=$d ATST_X_WAIT=5 mc_run_err start A_MT4
    ms=$(mc_ms_since "$t0")
    [ "$status" -eq 0 ]
    [ "$ms" -lt 1000 ]
    [ ! -s "$E" ]
    grep -qxF 'x_wait: ready (0 s)' "$HOME/.atst/wine_a_mt4.log"
  done
  [ "$(mc_wine_count)" -eq 4 ]
}

@test "MC-17: an empty DISPLAY (in the config) does not wait: x_wait: skipped (no display number)" {
  local t0 ms
  mc_stub_wine
  atst_test_set_config DISPLAY ''
  t0=$(date +%s%N)
  ATST_X_WAIT=5 mc_run_err start A_MT4
  ms=$(mc_ms_since "$t0")
  [ "$status" -eq 0 ]
  [ "$ms" -lt 1000 ]
  [ ! -s "$E" ]
  [ "$(mc_wine_count)" -eq 1 ]
  grep -qxF 'x_wait: skipped (no display number)' "$HOME/.atst/wine_a_mt4.log"
}

@test "MC-18: a wrong ATST_X_WAIT gives one stderr line and 120; -q says nothing; 600 and 1 are taken" {
  local v
  mc_stub_wine
  touch "$ATST_X11_DIR/X1"
  for v in abc 601 08 -1; do
    rm -f "$HOME/.atst/wine_a_mt4.log"
    DISPLAY=:1 ATST_X_WAIT=$v mc_run_err start A_MT4
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$E")" -eq 1 ]
    grep -q 'ATST_X_WAIT' "$E"
    grep -qxF 'x_wait: ready (0 s)' "$HOME/.atst/wine_a_mt4.log"

    DISPLAY=:1 ATST_X_WAIT=$v mc_run_err -q start A_MT4
    [ "$status" -eq 0 ]
    [ ! -s "$E" ]
    [ -z "$output" ]
  done
  for v in 600 1; do
    DISPLAY=:1 ATST_X_WAIT=$v mc_run_err start A_MT4
    [ "$status" -eq 0 ]
    [ ! -s "$E" ]
  done
}

@test "MC-19: x_wait: comes right after ===== START, auto_attach: right after it" {
  local log="$HOME/.atst/wine_a_mt4.log"
  mc_stub_wine
  touch "$ATST_X11_DIR/X1"
  mc_enable
  DISPLAY=:1 ATST_X_WAIT=5 mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  [ "$(grep -A1 '^===== START' "$log" | tail -1)" = 'x_wait: ready (0 s)' ]
  [[ "$(grep -A1 '^x_wait: ' "$log" | tail -1)" == 'auto_attach: '* ]]

  rm -f "$log"
  atst_test_set_config ATST_AUTO_ATTACH_EA 0
  DISPLAY=:1 ATST_X_WAIT=5 mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  [ "$(grep -A1 '^===== START' "$log" | tail -1)" = 'x_wait: ready (0 s)' ]
  [ "$(tail -1 "$log")" = 'x_wait: ready (0 s)' ]
}

@test "MC-20: while another mtctl.sh holds the MT lock, start skips (0) and restart does nothing (2)" {
  local L="$HOME/.atst/mtctl_a_mt4.lock"
  mc_stub_wine
  hold_lock "$L" || return 1
  mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  [ "$(mc_wine_count)" -eq 0 ]
  [ "$(wc -l < "$E")" -eq 1 ]
  grep -q busy "$E"
  [ ! -e "$HOME/.atst/wine_a_mt4.log" ]

  mc_run_err restart A_MT4
  [ "$status" -eq 2 ]
  [ "$(mc_wine_count)" -eq 0 ]
  [ "$(wc -l < "$E")" -eq 1 ]
  grep -q busy "$E"

  mc_run_err -q start A_MT4
  [ "$status" -eq 0 ]
  [ ! -s "$E" ]
  [ -z "$output" ]

  release_lock
  mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  [ "$(mc_wine_count)" -eq 1 ]
}

@test "MC-21: a process left by wine does not keep the MT lock (fd 6 is not passed on)" {
  local L="$HOME/.atst/mtctl_a_mt4.lock"
  mc_wine_body "sleep 30 >/dev/null 2>&1 </dev/null &
echo \$! > \"\$ATST_TEST_SANDBOX/child.pid\""
  mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  [ "$(mc_wine_count)" -eq 1 ]
  kill -0 "$(cat "$ATST_TEST_SANDBOX/child.pid")"
  flock -n "$L" true
}

@test "MC-21b: the wineserver that winepath leaves does not keep the MT lock (fd 6 is closed for winepath)" {
  local L="$HOME/.atst/mtctl_a_mt4.lock"
  export ATST_TEST_WINEPATH_CHILD="$ATST_TEST_SANDBOX/wp_child.pid"
  mc_run_err start A_MT4
  unset ATST_TEST_WINEPATH_CHILD
  [ "$status" -eq 0 ]
  kill -0 "$(cat "$ATST_TEST_SANDBOX/wp_child.pid")"
  flock -n "$L" true
  kill "$(cat "$ATST_TEST_SANDBOX/wp_child.pid")" 2>/dev/null || true
}

@test "MC-22: restart of a MetaTrader that is not running starts it (0) without stopping anything" {
  mc_stub_wine
  mc_run_err restart A_MT4
  [ "$status" -eq 0 ]
  [ "$(mc_wine_count)" -eq 1 ]
  [[ "$output" != *restarting:* ]]
  [[ "$output" == *executing:* ]]
  [ "$(grep -c '^x_wait: ' "$HOME/.atst/wine_a_mt4.log")" -eq 1 ]
}

@test "MC-23: start writes the epoch of the start to the MT lock (600); the alias A uses the same file" {
  local L="$HOME/.atst/mtctl_a_mt4.lock" now s1 s2
  mc_stub_wine
  mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  now=$(date +%s)
  s1=$(head -1 "$L")
  [[ "$s1" =~ ^[0-9]+$ ]]
  [ "$s1" -le "$now" ]
  [ "$s1" -ge $(( now - 5 )) ]
  [ "$(stat -c %a "$L")" = 600 ]
  mc_run_err start A
  [ "$status" -eq 0 ]
  [ "$(ls "$HOME"/.atst/mtctl_*.lock | wc -l)" -eq 1 ]
  s2=$(head -1 "$L")
  [ "$s2" -ge "$s1" ]
  [ "$(wc -l < "$L")" -eq 1 ]
}

@test "MC-24: the usage lists restart and ATST_X_WAIT; an unknown operation prints it and exits 1" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *restart* ]]
  [[ "$output" == *ATST_X_WAIT* ]]
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" foo A_MT4
  [ "$status" -eq 1 ]
  [[ "$output" == *restart* ]]
  [[ "$output" == *ATST_X_WAIT* ]]
}

@test "MC-25: atst_mt_lock_path gives one lock per MetaTrader folder and creates nothing" {
  atst_test_make_mt "X Y-1" MT4
  atst_test_source_common || return 1
  run atst_mt_lock_path A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "$ATST_CONFIG_DIR/mtctl_a_mt4.lock" ]
  run atst_mt_lock_path A
  [ "$status" -eq 0 ]
  [ "$output" = "$ATST_CONFIG_DIR/mtctl_a_mt4.lock" ]
  run atst_mt_lock_path "X Y-1"
  [ "$status" -eq 0 ]
  [ "$output" = "$ATST_CONFIG_DIR/mtctl_x_y_1.lock" ]
  run atst_mt_lock_path NO_SUCH
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run atst_mt_lock_path ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  ATST_CONFIG_DIR='' run atst_mt_lock_path A_MT4
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$(ls "$HOME"/.atst/mtctl_*.lock 2>/dev/null)" ]
}

@test "MC-26: wine is started in a new session and process group (setsid)" {
  local ids own_sid own_pgid
  command -v setsid > /dev/null || skip "no setsid"
  mc_wine_body 'ps -o pid=,pgid=,sid= -p $$ > "$ATST_TEST_SANDBOX/ids"'
  mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  read -r _ pgid sid < "$ATST_TEST_SANDBOX/ids"
  own_sid=$(ps -o sid= -p "$BASHPID" | tr -d ' ')
  own_pgid=$(ps -o pgid= -p "$BASHPID" | tr -d ' ')
  [ -n "$sid" ]
  [ "$sid" != "$own_sid" ]
  [ "$pgid" = "$sid" ]
  [ "$pgid" != "$own_pgid" ]
}

@test "MC-27: a setsid without --wait is not used and wine runs once" {
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  printf '#!/bin/bash\ncase "$1" in --help) echo "usage: setsid program" ; exit 0 ;; esac\necho setsid-called >> %q\nexec "$@"\n' \
    "$ATST_TEST_SANDBOX/calls.log" > "$ATST_TEST_SANDBOX/bin/setsid"
  chmod 755 "$ATST_TEST_SANDBOX/bin/setsid"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
  mc_stub_wine
  mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  [ "$(mc_wine_count)" -eq 1 ]
  [ "$(grep -c setsid-called "$ATST_TEST_SANDBOX/calls.log")" -eq 0 ]
  [ ! -s "$E" ]
}

@test "MC-28: a lock file that cannot be opened starts anyway with one line (no path)" {
  local L="$HOME/.atst/mtctl_a_mt4.lock"
  mc_stub_wine
  mkdir -p "$L"
  mc_run_err start A_MT4
  [ "$status" -eq 0 ]
  [ "$(mc_wine_count)" -eq 1 ]
  [ "$(wc -l < "$E")" -eq 1 ]
  grep -q 'ロック' "$E"
  [ "$(grep -cF "$HOME" "$E")" -eq 0 ]
  [ -d "$L" ]
}
