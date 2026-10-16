#!/usr/bin/env bats
# The old-style crontab keeps working (#95 AC1). The command parts of the lines of templates/crontab.txt
# as it was before #95 are fixed below word for word (the template itself has changed, so this file
# holds the compatibility contract) and run with sh -c as cron would, with TARGET in the environment
# and the repository first in PATH. sleep and the scripts that would start MetaTrader or send images
# are recording stubs. The old style never uses ATST_TARGETS and never runs check_all.sh.

load test_helper

# templates/crontab.txt before #95 (the lines after the time fields):
# TARGET="('Land Prime')"
LEGACY_DAILY='check_daily.sh'
LEGACY_REBOOT='check_reboot.sh'
LEGACY_HEARTBEAT='heartbeat.sh'
LEGACY_MTCTL='wrapper.sh                  "$TARGET" mtctl.sh start'
LEGACY_TRUNCATE='wrapper.sh                  "$TARGET" truncate_monitoring.sh'
LEGACY_REPORT='wrapper.sh                  "$TARGET" report_image.sh'
LEGACY_ORDER_10='sleep 10; wrapper.sh        "$TARGET" check_order.sh'
LEGACY_ORDER_40='sleep 40; wrapper.sh        "$TARGET" check_order.sh'
LEGACY_MONITORING='sleep_random.sh; wrapper.sh "$TARGET" check_monitoring.sh'
LEGACY_PROCESS='sleep_random.sh; wrapper.sh "$TARGET" check_process.sh'
LEGACY_PING='sleep_random.sh; wrapper.sh "$TARGET" check_ping.sh'
LEGACY_PRICE='sleep_random.sh; wrapper.sh "$TARGET" check_price.sh'
LEGACY_SPREAD='sleep_random.sh; wrapper.sh "$TARGET" check_spread.sh'

setup() {
  local n
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  atst_test_set_config ATST_CHECK_RANDOM_DELAY_MAX 1
  # The old style must not depend on ATST_TARGETS.
  sed -i '/^ATST_TARGETS=/d' "$HOME/.atst/config"
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  printf '#!/bin/bash\nexit 0\n' > "$ATST_TEST_SANDBOX/bin/sleep"
  chmod 755 "$ATST_TEST_SANDBOX/bin/sleep"
  for n in mtctl.sh truncate_monitoring.sh report_image.sh; do
    atst_test_stub_script "$ATST_TEST_SANDBOX/bin" "$n" record
  done
  PATH="$ATST_TEST_SANDBOX/bin:$repo:$PATH"
  export PATH
  hash -r
  [ "$(command -v mtctl.sh)" = "$ATST_TEST_SANDBOX/bin/mtctl.sh" ]
  [ "$(command -v wrapper.sh)" = "$repo/wrapper.sh" ]
  TARGET="('A_MT4')"
  export TARGET
  CALLS="$ATST_TEST_SANDBOX/calls.log"
  ST="$HOME/.atst/alert_status"
  F="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files"
}

teardown() {
  atst_test_teardown_sandbox
}

# The old style leaves no trace of check_all.sh (C-LG-8).
no_runner_trace() {
  { [ ! -e "$ST" ] || [ "$(grep -c '^RUNNER_' "$ST")" -eq 0 ]; } && [ ! -e "$HOME/.atst/check_all.started" ]
}

@test "LG-1: the check_process line reports a stopped MetaTrader once" {
  atst_test_make_mt A_MT4 MT4
  run sh -c "$LEGACY_PROCESS"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^PROCESS_' "$ST")" -eq 1 ]
  no_runner_trace
}

@test "LG-2: the two check_order lines send one order once and consume order_status" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_order_status A_MT4 'order one'
  run sh -c "$LEGACY_ORDER_10"
  [ "$status" -eq 0 ]
  run sh -c "$LEGACY_ORDER_40"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -q 'order one' "$ATST_TEST_CURL_LOG"
  [ ! -e "$F/order_status" ]
  [ ! -e "$F/order_status.pending" ]
  no_runner_trace
}

@test "LG-3: the check_monitoring line reports stale data once; ping, price and spread lines run" {
  local cmd
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  run sh -c "$LEGACY_MONITORING"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^MONITORING_' "$ST")" -eq 1 ]
  for cmd in "$LEGACY_PING" "$LEGACY_PRICE" "$LEGACY_SPREAD"; do
    run sh -c "$cmd"
    [ "$status" -eq 0 ] || { echo "cmd=$cmd"; false; }
  done
  [ "$(atst_test_push_count)" -eq 1 ]
  no_runner_trace
}

@test "LG-4: the check_reboot line reports a reboot once; the heartbeat line without a URL sends nothing" {
  mkdir -p "$HOME/.atst"
  echo '9999999999.00 0.00' > "$HOME/.atst/uptime"
  run sh -c "$LEGACY_REBOOT"
  [ "$status" -eq 0 ]
  run sh -c "$LEGACY_REBOOT"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  run sh -c "$LEGACY_HEARTBEAT"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  no_runner_trace
}

@test "LG-5: the mtctl, truncate and report lines pass the TARGET names element by element" {
  local expected
  TARGET="('A_MT4' \"it's\" 'a  b')"
  run sh -c "$LEGACY_MTCTL"
  [ "$status" -eq 0 ]
  run sh -c "$LEGACY_TRUNCATE"
  [ "$status" -eq 0 ]
  run sh -c "$LEGACY_REPORT"
  [ "$status" -eq 0 ]
  expected="mtctl.sh [start] [A_MT4] [it's] [a  b]
truncate_monitoring.sh [A_MT4] [it's] [a  b]
report_image.sh [A_MT4] [it's] [a  b]"
  [ "$(sed -E 's/ [0-9]+//' "$CALLS")" = "$expected" ]
  no_runner_trace
}

@test "LG-6: wrapper.sh with only the TARGET prints the usage and exits 1" {
  run sh -c 'wrapper.sh "$TARGET"'
  [ "$status" -eq 1 ]
  [[ "$output" == Usage* ]]
  no_runner_trace
}
