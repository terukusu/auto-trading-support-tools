#!/usr/bin/env bats
# check_reboot.sh: records /proc/uptime and reports a reboot when it went down since the last run
# (PR #78). The record lives in the sandbox ~/.atst, never the real one.

load test_helper

setup() {
  atst_test_setup_sandbox
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

@test "R1: without a previous record it only records /proc/uptime" {
  run bash "$BATS_TEST_DIRNAME/../check_reboot.sh"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
  [[ "$(cat "$HOME/.atst/uptime")" =~ ^[0-9]+\.[0-9]+\ [0-9]+\.[0-9]+$ ]]
}

@test "R2: a recorded uptime larger than now sends one reboot notice" {
  mkdir -p "$HOME/.atst"
  echo '9999999999.00 0.00' > "$HOME/.atst/uptime"
  run bash "$BATS_TEST_DIRNAME/../check_reboot.sh"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q '再起動を検出' "$ATST_TEST_CURL_LOG"
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "R2: a recorded uptime smaller than now sends nothing" {
  mkdir -p "$HOME/.atst"
  echo '0.10 0.00' > "$HOME/.atst/uptime"
  run bash "$BATS_TEST_DIRNAME/../check_reboot.sh"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
}

@test "RB-01: two runs at once after a reboot send one notice (#95)" {
  local i p1 p2
  mkdir -p "$ATST_TEST_SANDBOX/bin" "$HOME/.atst"
  # A curl taking 0.5 seconds, so the two runs overlap.
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
  for i in 1 2 3 4 5; do
    echo '9999999999.00 0.00' > "$HOME/.atst/uptime"
    rm -f "$ATST_TEST_CURL_LOG"
    bash "$BATS_TEST_DIRNAME/../check_reboot.sh" >/dev/null 2>&1 </dev/null 3>&- &
    p1=$!
    bash "$BATS_TEST_DIRNAME/../check_reboot.sh" >/dev/null 2>&1 </dev/null 3>&- &
    p2=$!
    wait "$p1" || true
    wait "$p2" || true
    [ "$(push_count)" -eq 1 ] || { echo "round $i: push=$(push_count)"; false; }
    [[ "$(cat "$HOME/.atst/uptime")" =~ ^[0-9]+\.[0-9]+\ [0-9]+\.[0-9]+$ ]]
  done
}

@test "RB-02: an uptime.lock that cannot be opened still reports the reboot, with a message" {
  mkdir -p "$HOME/.atst/uptime.lock"
  echo '9999999999.00 0.00' > "$HOME/.atst/uptime"
  run bash "$BATS_TEST_DIRNAME/../check_reboot.sh"
  [ "$(push_count)" -eq 1 ]
  [[ "$(cat "$HOME/.atst/uptime")" =~ ^[0-9]+\.[0-9]+\ [0-9]+\.[0-9]+$ ]]
  [ -n "$output" ]
}
