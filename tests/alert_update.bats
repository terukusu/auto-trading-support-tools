#!/usr/bin/env bats
# atst_alert_transition / atst_update_alert (common.sh): the transition table without side effects,
# and one push per due message with the state recorded only after a successful send (#92).

load test_helper

setup() {
  atst_test_setup_sandbox
  atst_test_source_common
}

teardown() {
  local pid
  pid=$(cat "$ATST_TEST_SANDBOX/holder.pid" 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null ;;
  esac
  atst_test_teardown_sandbox
}

set_status() {
  printf '%s\n' "$1" > "$ATST_ALERT_STATUS_FILE"
}

no_key_line() {
  [ ! -e "$ATST_ALERT_STATUS_FILE" ] || [ "$(grep -c '^KEY,' "$ATST_ALERT_STATUS_FILE")" -eq 0 ]
}

@test "U1: verdict 1 gives 1 without a line or with 0, and nothing with 1" {
  [ "$(atst_alert_transition KEY 1)" = "1" ]
  set_status 'KEY,0,0'
  [ "$(atst_alert_transition KEY 1)" = "1" ]
  set_status 'KEY,1,0'
  [ -z "$(atst_alert_transition KEY 1)" ]
}

@test "U2: verdict 0 gives 0 with 1, and nothing with 0 or without a line" {
  set_status 'KEY,1,0'
  [ "$(atst_alert_transition KEY 0)" = "0" ]
  set_status 'KEY,0,0'
  [ -z "$(atst_alert_transition KEY 0)" ]
  set_status 'OTHER,1,0'
  [ -z "$(atst_alert_transition KEY 0)" ]
}

@test "U3: an empty verdict gives nothing with or without a line" {
  run atst_alert_transition KEY ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  set_status 'KEY,1,0'
  run atst_alert_transition KEY ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "U4: atst_alert_transition creates no alert_status and pushes nothing" {
  run atst_alert_transition KEY 1
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run atst_alert_transition KEY 0
  [ "$status" -eq 0 ]
  [ ! -e "$ATST_ALERT_STATUS_FILE" ]
  [ ! -e "$ATST_ALERT_STATUS_FILE.lock" ]
  [ ! -e "$ATST_TEST_CURL_LOG" ]
}

@test "U5: atst_update_alert with 200 pushes once, records KEY,1,<epoch> and returns 0" {
  run atst_update_alert KEY 1 "fire-u5" "recover-u5"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -q 'fire-u5' "$ATST_TEST_CURL_LOG"
  grep -q '^KEY,1,[0-9][0-9]*$' "$ATST_ALERT_STATUS_FILE"
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "U6: atst_update_alert with alert 1 and verdict 0 sends recover_msg and records 0" {
  set_status 'KEY,1,0'
  run atst_update_alert KEY 0 "fire-u6" "recover-u6"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -q 'recover-u6' "$ATST_TEST_CURL_LOG"
  [ "$(grep -c 'fire-u6' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  grep -q '^KEY,0,' "$ATST_ALERT_STATUS_FILE"
}

@test "U7: atst_update_alert with 500 pushes once, records nothing and returns 1" {
  export ATST_TEST_CURL_HTTP_CODE=500
  run atst_update_alert KEY 1 "fire-u7" "recover-u7"
  [ "$status" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  no_key_line
  [ -e "$ATST_CONFIG_DIR/line_error.log" ]
}

@test "U8: atst_update_alert with 400 pushes once, records nothing and returns 1" {
  export ATST_TEST_CURL_HTTP_CODE=400
  run atst_update_alert KEY 1 "fire-u8" "recover-u8"
  [ "$status" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  no_key_line
}

@test "U9: an invalid verdict or key returns non-zero, pushes nothing and records nothing" {
  run atst_update_alert KEY 2 "fire" "recover"
  [ "$status" -ne 0 ]
  [ -n "$output" ]
  run atst_update_alert KEY x "fire" "recover"
  [ "$status" -ne 0 ]
  [ -n "$output" ]
  run atst_update_alert "" 1 "fire" "recover"
  [ "$status" -ne 0 ]
  run atst_update_alert KEY 1 "fire"
  [ "$status" -eq 2 ]
  run atst_alert_transition KEY 2
  [ "$status" -ne 0 ]
  [ "$(atst_alert_transition KEY x 2>/dev/null)" = "" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ ! -e "$ATST_ALERT_STATUS_FILE" ]
}

@test "U10: atst_update_alert with alert 1 and verdict 1 does nothing and returns 0" {
  set_status 'KEY,1,0'
  run atst_update_alert KEY 1 "fire-u10" "recover-u10"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  grep -q '^KEY,1,0$' "$ATST_ALERT_STATUS_FILE"
}

# A curl in front of tests/stubs/curl that takes 0.5 seconds, so two sends overlap.
make_slow_curl() {
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  {
    printf '#!/bin/bash\n'
    printf '%q 0.5\n' "$(command -v sleep)"
    printf 'exec %q "$@"\n' "$BATS_TEST_DIRNAME/stubs/curl"
  } > "$ATST_TEST_SANDBOX/bin/curl"
  chmod 755 "$ATST_TEST_SANDBOX/bin/curl"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
  hash -r
  [ "$(command -v curl)" = "$ATST_TEST_SANDBOX/bin/curl" ]
}

# Starts a process holding the lock on $1 and waits until it holds it (the probe cannot take it away:
# the holder waits for it with a blocking flock).
hold_lock() {
  local i
  ( exec 8>>"$1"; flock 8; exec sleep 30 ) >/dev/null 2>&1 </dev/null 3>&- &
  echo "$!" > "$ATST_TEST_SANDBOX/holder.pid"
  for i in $(seq 1 20); do
    flock -n "$1" true || return 0
    sleep 0.1
  done
  return 1
}

@test "UA-01: the same transition from two processes at once is sent once and both return 0 (#95)" {
  local i p1 p2 r1 r2
  make_slow_curl
  for i in 1 2 3 4 5; do
    rm -f "$ATST_ALERT_STATUS_FILE" "$ATST_TEST_CURL_LOG"
    ( atst_update_alert K 1 fire rec ) >/dev/null 2>&1 </dev/null 3>&- &
    p1=$!
    ( atst_update_alert K 1 fire rec ) >/dev/null 2>&1 </dev/null 3>&- &
    p2=$!
    r1=0; wait "$p1" || r1=$?
    r2=0; wait "$p2" || r2=$?
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "round $i: push=$(atst_test_push_count)"; false; }
    [ "$(grep -c '^K,1,' "$ATST_ALERT_STATUS_FILE")" -eq 1 ]
    [ "$r1" -eq 0 ] || { echo "round $i: r1=$r1"; false; }
    [ "$r2" -eq 0 ] || { echo "round $i: r2=$r2"; false; }
  done
}

@test "UA-02: no transition creates no lock file; the lock file is per key with safe chars" {
  atst_update_alert K 0 f r
  set_status 'K,1,0'
  atst_update_alert K 1 f r
  [ "$(atst_test_push_count)" -eq 0 ]
  run compgen -G "$HOME/.atst/alert_update.*.lock"
  [ "$status" -ne 0 ]
  atst_update_alert 'A B-c' 1 f r
  [ -e "$HOME/.atst/alert_update.A_B_c.lock" ]
}

@test "UA-03: a held lock of one key does not delay another key" {
  local t0 el rc=0
  hold_lock "$HOME/.atst/alert_update.A.lock"
  t0=$(date +%s)
  atst_update_alert B 1 f r || rc=$?
  el=$(( $(date +%s) - t0 ))
  [ "$rc" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$el" -lt 5 ]
  grep -q '^B,1,' "$ATST_ALERT_STATUS_FILE"
}

@test "UA-04: a lock file that cannot be opened still sends and records, with a message" {
  mkdir -p "$HOME/.atst/alert_update.K.lock"
  run atst_update_alert K 1 f r
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -q '^K,1,' "$ATST_ALERT_STATUS_FILE"
  [ -n "$output" ]
}
