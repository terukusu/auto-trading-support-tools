#!/usr/bin/env bats
# Old-style crontab lines and check_all.sh in the same crontab (#95 AC7): one event gives one LINE
# push whether the old line runs first, the runner runs first, or both run at the same time.
# The old commands run from the repository (PATH, TARGET as cron passes it), the runner from a copy
# whose checks are recording stubs except the one under test. A curl taking 0.5 seconds widens the
# window in which two runs overlap; the result is still decided by the locks (atst_update_alert per
# key, uptime.lock, check_order.lock), not by timing.

load ../test_helper

CHECKS="check_reboot check_order check_process check_monitoring check_ping check_price check_spread heartbeat"

setup() {
  local n
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  home=$(atst_test_make_runner_home)
  atst_test_set_targets A_MT4
  atst_test_set_config ATST_CHECK_TIMEOUT 2
  atst_test_set_config ATST_ORDER_CHECK_INTERVAL 0
  atst_test_set_config ATST_CHECK_RANDOM_DELAY_MAX 1
  for n in $CHECKS; do
    atst_test_stub_script "$home" "$n.sh" record
  done
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  {
    printf '#!/bin/bash\n'
    printf '%q 0.5\n' "$(command -v sleep)"
    printf 'exec %q "$@"\n' "$BATS_TEST_DIRNAME/../stubs/curl"
  } > "$ATST_TEST_SANDBOX/bin/curl"
  chmod 755 "$ATST_TEST_SANDBOX/bin/curl"
  PATH="$ATST_TEST_SANDBOX/bin:$repo:$PATH"
  export PATH
  hash -r
  [ "$(command -v curl)" = "$ATST_TEST_SANDBOX/bin/curl" ]
  [ "$(command -v wrapper.sh)" = "$repo/wrapper.sh" ]
  TARGET="('A_MT4')"
  export TARGET
  ST="$HOME/.atst/alert_status"
  F="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files"
}

teardown() {
  atst_test_teardown_sandbox
}

# Clears what the previous round recorded or sent.
reset_round() {
  rm -f "$ST" "$ATST_TEST_CURL_LOG" "$ATST_TEST_SANDBOX/calls.log"
}

expect_one_push() {
  [ "$(atst_test_push_count)" -eq 1 ] || { echo "$1: push=$(atst_test_push_count)"; return 1; }
}

# each_way <prepare function> <old command>
# Old then new, new then old, and both at once five times; each round must give exactly one push.
each_way() {
  local prepare="$1" old="$2" i p1 p2

  reset_round; "$prepare"
  sh -c "$old" >/dev/null 2>&1 </dev/null || true
  bash "$home/check_all.sh" >/dev/null 2>&1 </dev/null
  expect_one_push "old then new"

  reset_round; "$prepare"
  bash "$home/check_all.sh" >/dev/null 2>&1 </dev/null
  sh -c "$old" >/dev/null 2>&1 </dev/null || true
  expect_one_push "new then old"

  for i in 1 2 3 4 5; do
    reset_round; "$prepare"
    sh -c "$old" >/dev/null 2>&1 </dev/null 3>&- &
    p1=$!
    bash "$home/check_all.sh" >/dev/null 2>&1 </dev/null 3>&- &
    p2=$!
    wait "$p1" || true
    wait "$p2" || true
    expect_one_push "same time, round $i"
  done
}

no_prepare() {
  :
}

prepare_order() {
  rm -f "$F"/order_status*
  atst_test_make_order_status A_MT4 'order one'
}

prepare_reboot() {
  mkdir -p "$HOME/.atst"
  echo '9999999999.00 0.00' > "$HOME/.atst/uptime"
}

@test "CX-1: a stopped MetaTrader gives one push (PROCESS_)" {
  cp -p "$repo/check_process.sh" "$home/"
  atst_test_make_mt A_MT4 MT4
  each_way no_prepare 'sleep_random.sh; wrapper.sh "$TARGET" check_process.sh'
  [ "$(grep -c '^PROCESS_' "$ST")" -eq 1 ]
}

@test "CX-2: one order gives one push" {
  cp -p "$repo/check_order.sh" "$home/"
  atst_test_make_mt A_MT4 MT4
  each_way prepare_order 'wrapper.sh        "$TARGET" check_order.sh'
}

@test "CX-3: one reboot gives one push" {
  cp -p "$repo/check_reboot.sh" "$home/"
  each_way prepare_reboot 'check_reboot.sh'
}

@test "CX-4: stale monitoring data gives one push (MONITORING_)" {
  cp -p "$repo/check_monitoring.sh" "$home/"
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  each_way no_prepare 'sleep_random.sh; wrapper.sh "$TARGET" check_monitoring.sh'
  [ "$(grep -c '^MONITORING_' "$ST")" -eq 1 ]
}
