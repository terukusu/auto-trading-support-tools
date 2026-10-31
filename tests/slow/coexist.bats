#!/usr/bin/env bats
# A check started by hand and check_all.sh in the same minute (#95 AC7, #176): one event gives one LINE
# push whether the check runs first, the runner runs first, or both run at the same time.
# The checks run from the repository (on PATH), the runner from a copy whose checks are recording
# stubs except the one under test. A curl taking 0.5 seconds widens the
# window in which two runs overlap; the result is still decided by the locks (atst_update_alert per
# key, uptime.lock, check_order.lock), not by timing.

load ../test_helper

CHECKS="check_reboot check_order check_process check_monitoring check_tick check_trade_ready check_margin check_ping check_price check_spread heartbeat"

setup() {
  local n
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  home=$(atst_test_make_runner_home)
  atst_test_set_targets A_MT4
  atst_test_set_config ATST_CHECK_TIMEOUT 2
  atst_test_set_config ATST_ORDER_CHECK_INTERVAL 0
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

# each_way <prepare function> <other command>
# The command then check_all.sh, check_all.sh then the command, and both at once five times; each round
# must give exactly one push.
each_way() {
  local prepare="$1" other="$2" i p1 p2

  reset_round; "$prepare"
  sh -c "$other" >/dev/null 2>&1 </dev/null || true
  bash "$home/check_all.sh" >/dev/null 2>&1 </dev/null
  expect_one_push "other then runner"

  reset_round; "$prepare"
  bash "$home/check_all.sh" >/dev/null 2>&1 </dev/null
  sh -c "$other" >/dev/null 2>&1 </dev/null || true
  expect_one_push "runner then other"

  for i in 1 2 3 4 5; do
    reset_round; "$prepare"
    sh -c "$other" >/dev/null 2>&1 </dev/null 3>&- &
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
  each_way no_prepare 'check_process.sh A_MT4'
  [ "$(grep -c '^PROCESS_' "$ST")" -eq 1 ]
}

@test "CX-2: one order gives one push" {
  cp -p "$repo/check_order.sh" "$home/"
  atst_test_make_mt A_MT4 MT4
  each_way prepare_order 'check_order.sh A_MT4'
}

@test "CX-3: one reboot gives one push" {
  cp -p "$repo/check_reboot.sh" "$home/"
  each_way prepare_reboot 'check_reboot.sh'
}

@test "CX-4: stale monitoring data gives one push (MONITORING_)" {
  cp -p "$repo/check_monitoring.sh" "$home/"
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  each_way no_prepare 'check_monitoring.sh A_MT4'
  [ "$(grep -c '^MONITORING_' "$ST")" -eq 1 ]
}
