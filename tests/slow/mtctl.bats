#!/usr/bin/env bats
# mtctl.sh (#140), the slow part: the X wait that waits (timeout, ready, once per run, under the MT lock),
# restart of real processes (TERM, KILL, one that cannot be stopped) and a MetaTrader that outlives the
# timeout of its caller (setsid). wine is always the record stub of the sandbox (calls.log); the real
# processes are "sleep" shown as terminal.exe, killed by pid in teardown.

load ../test_helper

setup() {
  atst_test_setup_sandbox
  atst_test_make_mt A_MT4 MT4
  mkdir -p "$ATST_TEST_SANDBOX/x11"
  ATST_X11_DIR="$ATST_TEST_SANDBOX/x11"
  export ATST_X11_DIR
  unset ATST_X_WAIT
  atst_test_stub_script "$ATST_TEST_SANDBOX" wine record
  WINE="$ATST_TEST_SANDBOX/wine"
  export WINE
  M="$BATS_TEST_DIRNAME/../../mtctl.sh"
  E="$ATST_TEST_SANDBOX/err"
  L="$HOME/.atst/mtctl_a_mt4.lock"
}

teardown() {
  local f pid k
  for f in fake.pid child.pid stub.pid bg.pid; do
    pid=$(cat "$ATST_TEST_SANDBOX/$f" 2>/dev/null)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        kill -KILL "$pid" 2>/dev/null
        for k in $(seq 1 10); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.1
        done
        ;;
    esac
  done
  atst_test_teardown_sandbox
}

# ms_run_err <mtctl args...>: stdout in $output, stderr in $E.
ms_run_err() {
  run bash -c 'f=$1; shift; bash "$@" 2>"$f"' _ "$E" "$M" "$@"
}

ms_since() {
  echo $(( ($(date +%s%N) - $1) / 1000000 ))
}

wine_count() {
  if [ -e "$ATST_TEST_SANDBOX/calls.log" ]; then
    grep -c '^wine ' "$ATST_TEST_SANDBOX/calls.log"
  else
    echo 0
  fi
}

own_env() {
  printf 'HOME=%s\nWINEPREFIX=%s' "$HOME" "$WINEPREFIX"
}

win_term() {
  printf 'C:\\Program Files\\%s\\terminal.exe' "$1"
}

# A "terminal.exe" of <name> that ignores TERM (only KILL ends it). Prints its pid.
fake_ignoring_term() {
  ( trap '' TERM; exec -a "C:\\Program Files\\$1\\terminal.exe" sleep 40 ) >/dev/null 2>&1 </dev/null 3>&- &
  echo "$!"
}

@test "MS-01: no X socket within ATST_X_WAIT=2: starts anyway after 2 s, one x_wait line, -q silent" {
  local t0 ms
  t0=$(date +%s%N)
  DISPLAY=:1 ATST_X_WAIT=2 ms_run_err start A_MT4
  ms=$(ms_since "$t0")
  [ "$status" -eq 0 ]
  [ "$ms" -ge 2000 ]
  [ "$ms" -lt 5000 ]
  [ "$(wc -l < "$E")" -eq 1 ]
  grep -q 'x_wait' "$E"
  [ "$(wine_count)" -eq 1 ]
  grep -qxF 'x_wait: timeout (2 s)' "$HOME/.atst/wine_a_mt4.log"

  DISPLAY=:1 ATST_X_WAIT=2 ms_run_err -q start A_MT4
  [ "$status" -eq 0 ]
  [ ! -s "$E" ]
  [ -z "$output" ]
  [ "$(wine_count)" -eq 2 ]
}

@test "MS-02: the X socket that appears after 1 s starts at once (:1, :1.0, localhost:1)" {
  local d t0 ms log="$HOME/.atst/wine_a_mt4.log" line
  for d in :1 :1.0 localhost:1; do
    rm -f "$ATST_X11_DIR/X1" "$log"
    ( sleep 1; touch "$ATST_X11_DIR/X1" ) &
    t0=$(date +%s%N)
    DISPLAY=$d ATST_X_WAIT=10 ms_run_err start A_MT4
    ms=$(ms_since "$t0")
    wait
    [ "$status" -eq 0 ]
    [ "$ms" -lt 3000 ]
    [ ! -s "$E" ]
    line=$(grep '^x_wait: ' "$log")
    [[ "$line" =~ ^x_wait:\ ready\ \([12]\ s\)$ ]]
  done
  [ "$(wine_count)" -eq 3 ]
}

@test "MS-03: two MetaTraders wait for X once: the second says skipped (already waited)" {
  local t0 ms
  atst_test_make_mt B_MT4 MT4
  t0=$(date +%s%N)
  DISPLAY=:1 ATST_X_WAIT=2 ms_run_err start A_MT4 B_MT4
  ms=$(ms_since "$t0")
  [ "$status" -eq 0 ]
  [ "$ms" -ge 2000 ]
  [ "$ms" -lt 5000 ]
  grep -qxF 'x_wait: timeout (2 s)' "$HOME/.atst/wine_a_mt4.log"
  grep -qxF 'x_wait: skipped (already waited)' "$HOME/.atst/wine_b_mt4.log"
  [ "$(wc -l < "$E")" -eq 1 ]
  [ "$(wine_count)" -eq 2 ]
}

@test "MS-04: the MT lock is held while waiting for X and free afterwards; a restart meanwhile exits 2" {
  ( DISPLAY=:1 ATST_X_WAIT=3 bash "$M" -q start A_MT4 ) &
  echo "$!" > "$ATST_TEST_SANDBOX/bg.pid"
  sleep 1
  if flock -n "$L" true; then return 1; fi
  run bash "$M" -q restart A_MT4
  [ "$status" -eq 2 ]
  wait "$(cat "$ATST_TEST_SANDBOX/bg.pid")"
  rm -f "$ATST_TEST_SANDBOX/bg.pid"
  flock -n "$L" true
  [ "$(wine_count)" -eq 1 ]
}

@test "MS-05: restart stops a running MetaTrader by TERM and starts it (0)" {
  local t0 ms pid
  export ATST_PROC_ROOT=/proc
  atst_test_make_mt ATSTTEST_MT4 MT4
  pid=$(atst_test_fake_mt_process ATSTTEST_MT4)
  echo "$pid" > "$ATST_TEST_SANDBOX/fake.pid"
  t0=$(date +%s%N)
  DISPLAY=:1 ATST_X_WAIT=0 ms_run_err restart ATSTTEST_MT4
  ms=$(ms_since "$t0")
  [ "$status" -eq 0 ]
  [ "$ms" -lt 3000 ]
  if kill -0 "$pid" 2>/dev/null; then return 1; fi
  [ "$(wine_count)" -eq 1 ]
  [[ "$output" == *"restarting: pid=$pid"* ]]
}

@test "MS-06: restart of a MetaTrader ignoring TERM stops it by KILL after 15 s and starts it (0)" {
  local t0 ms pid
  export ATST_PROC_ROOT=/proc
  atst_test_make_mt ATSTTEST_MT4 MT4
  pid=$(fake_ignoring_term ATSTTEST_MT4)
  echo "$pid" > "$ATST_TEST_SANDBOX/fake.pid"
  sleep 0.2
  t0=$(date +%s%N)
  DISPLAY=:1 ATST_X_WAIT=0 ms_run_err restart ATSTTEST_MT4
  ms=$(ms_since "$t0")
  [ "$status" -eq 0 ]
  [ "$ms" -ge 15000 ]
  [ "$ms" -lt 25000 ]
  if kill -0 "$pid" 2>/dev/null; then return 1; fi
  [ "$(wine_count)" -eq 1 ]
  [ ! -s "$E" ]
}

@test "MS-07: a process that cannot be stopped is not started again: exit 1, one line, no wine" {
  local t0 ms
  # pid_max is at most 4194304: this pid cannot be a real process, so nothing real is signalled.
  atst_test_make_proc 99999999 - "$(own_env)" "$(win_term A_MT4)"
  t0=$(date +%s%N)
  DISPLAY=:1 ATST_X_WAIT=0 ms_run_err restart A_MT4
  ms=$(ms_since "$t0")
  [ "$status" -eq 1 ]
  [ "$ms" -ge 20000 ]
  [ "$ms" -lt 26000 ]
  [ "$(wine_count)" -eq 0 ]
  [ "$(wc -l < "$E")" -eq 1 ]
  grep -q 'pid=99999999' "$E"
}

@test "MS-08: the MetaTrader started by wine outlives the timeout that cuts off mtctl.sh (setsid)" {
  local t0 ms rc
  command -v setsid > /dev/null || skip "no setsid"
  sed -i '$d' "$WINE"
  cat >> "$WINE" <<'STUB'
echo $$ > "$ATST_TEST_SANDBOX/stub.pid"
( exec -a "C:\\Program Files\\A_MT4\\terminal.exe" sleep 30 ) </dev/null >/dev/null 2>&1 &
echo $! > "$ATST_TEST_SANDBOX/child.pid"
sleep 8
exit 0
STUB
  t0=$(date +%s%N)
  run env DISPLAY=:1 ATST_X_WAIT=0 timeout -k 1 2 bash "$M" -q start A_MT4
  rc=$status
  ms=$(ms_since "$t0")
  [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]
  [ "$ms" -lt 5000 ]
  sleep 1
  kill -0 "$(cat "$ATST_TEST_SANDBOX/child.pid")"
}
