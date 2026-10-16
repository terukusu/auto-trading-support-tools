#!/usr/bin/env bats
# check_order.sh: order notifications are taken from order_status, kept in .pending until LINE accepts
# them, split below the text limit, and set aside to .failed when LINE rejects them (PR #72, #78).
# $status is 0 on every normal path, including a held lock (O4); only a missing argument or a lock
# file that cannot be opened exits 1 (#101).

load test_helper

setup() {
  atst_test_setup_sandbox
  F="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files"
}

teardown() {
  atst_test_teardown_sandbox
}

push_count() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep -c 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

# A curl in front of tests/stubs/curl: 200 for the short "not accepted" notice, 400 for anything else.
make_rejecting_curl() {
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  cat > "$ATST_TEST_SANDBOX/bin/curl" <<'EOS'
#!/bin/bash
case "$*" in
  *受け付けませんでした*) ATST_TEST_CURL_HTTP_CODE=200 ;;
  *) ATST_TEST_CURL_HTTP_CODE=400 ;;
esac
export ATST_TEST_CURL_HTTP_CODE
exec "$ATST_TEST_STUBS/curl" "$@"
EOS
  chmod +x "$ATST_TEST_SANDBOX/bin/curl"
  export ATST_TEST_STUBS="$BATS_TEST_DIRNAME/stubs" PATH="$ATST_TEST_SANDBOX/bin:$PATH"
}

@test "O1: check_order.sh sends two orders in one push and removes order_status and .pending" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_order_status A_MT4 'order one' 'order two'
  run bash "$BATS_TEST_DIRNAME/../check_order.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q 'order one' "$ATST_TEST_CURL_LOG"
  grep -q 'order two' "$ATST_TEST_CURL_LOG"
  [ ! -e "$F/order_status" ]
  [ ! -e "$F/order_status.pending" ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "O2: a failed send keeps .pending and the next run sends it together with new orders" {
  local last
  atst_test_make_mt A_MT4 MT4
  atst_test_make_order_status A_MT4 'order first'
  ATST_TEST_CURL_HTTP_CODE=500 run bash "$BATS_TEST_DIRNAME/../check_order.sh" A_MT4
  [ -s "$F/order_status.pending" ]
  [ ! -e "$F/order_status" ]
  atst_test_make_order_status A_MT4 'order second'
  ATST_TEST_CURL_HTTP_CODE=200 run bash "$BATS_TEST_DIRNAME/../check_order.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 2 ]
  last=$(grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | tail -1)
  [[ "$last" == *'order first'* ]]
  [[ "$last" == *'order second'* ]]
  [ ! -e "$F/order_status.pending" ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "O3: a leftover .taking is collected and sent on the next run" {
  atst_test_make_mt A_MT4 MT4
  mkdir -p "$F"
  printf 'left over\n' > "$F/order_status.taking"
  run bash "$BATS_TEST_DIRNAME/../check_order.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q 'left over' "$ATST_TEST_CURL_LOG"
  [ ! -e "$F/order_status.taking" ]
  [ ! -e "$F/order_status.pending" ]
}

@test "O4: a held check_order.lock makes it exit 0 without sending" {
  local lock="$HOME/.atst/check_order.lock" holder k locked=0
  atst_test_make_mt A_MT4 MT4
  atst_test_make_order_status A_MT4 'order held'
  mkdir -p "$HOME/.atst"
  ( exec 8>>"$lock"; flock 8; exec sleep 5 ) >/dev/null 2>&1 </dev/null 3>&- &
  holder=$!
  for k in $(seq 1 20); do
    if ! flock -n "$lock" true; then
      locked=1
      break
    fi
    sleep 0.1
  done
  run bash "$BATS_TEST_DIRNAME/../check_order.sh" A_MT4
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$locked" -eq 1 ]
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
  [ "$(cat "$F/order_status")" = 'order held' ]
}

@test "O5: a chunk LINE rejects (400) goes to .failed with one short notice" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_order_status A_MT4 'order rejected'
  make_rejecting_curl
  run bash "$BATS_TEST_DIRNAME/../check_order.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(cat "$F/order_status.failed")" = 'order rejected' ]
  [ "$(push_count)" -eq 2 ]
  [ "$(grep -c '受け付けませんでした' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -qF "$F/order_status.failed" "$ATST_TEST_CURL_LOG"
  [ ! -e "$F/order_status.pending" ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "O6: pending orders over 4500 characters are split into several pushes" {
  local n line missing=""
  local lines=()
  atst_test_make_mt A_MT4 MT4
  for n in $(seq 1 100); do
    lines+=("$(printf 'order-%044d' "$n")")
  done
  atst_test_make_order_status A_MT4 "${lines[@]}"
  run bash "$BATS_TEST_DIRNAME/../check_order.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -ge 2 ]
  for line in "${lines[@]}"; do
    grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | grep -qF "$line" || missing+=" $line"
  done
  [ -z "$missing" ]
  [ ! -e "$F/order_status.pending" ]
}

@test "O7: an unknown name sends nothing and leaves other MTs' order_status" {
  atst_test_make_mt B_MT4 MT4
  atst_test_make_order_status B_MT4 'order of b'
  run bash "$BATS_TEST_DIRNAME/../check_order.sh" NOSUCH
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
  [ "$(cat "$WINEPREFIX/drive_c/Program Files/B_MT4/MQL4/Files/order_status")" = 'order of b' ]
}

@test "O8: no argument prints usage and exits 1" {
  run bash "$BATS_TEST_DIRNAME/../check_order.sh"
  [ "$status" -eq 1 ]
  [ "$(push_count)" -eq 0 ]
}

@test "O9: two names exit 0 and send each MT's orders" {
  local fb="$WINEPREFIX/drive_c/Program Files/B_MT4/MQL4/Files"
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt B_MT4 MT4
  atst_test_make_order_status A_MT4 'order of a'
  atst_test_make_order_status B_MT4 'order of b'
  run bash "$BATS_TEST_DIRNAME/../check_order.sh" A_MT4 B_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 2 ]
  grep -q 'order of a' "$ATST_TEST_CURL_LOG"
  grep -q 'order of b' "$ATST_TEST_CURL_LOG"
  [ ! -e "$F/order_status" ]
  [ ! -e "$fb/order_status" ]
}
