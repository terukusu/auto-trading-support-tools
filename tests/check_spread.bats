#!/usr/bin/env bats
# check_spread.sh: alert on the 5-minute spread maximum.
# Relies on the default thresholds of templates/config (ATST_THRESHOLD_SPREAD_UPPER=60,
# ATST_THRESHOLD_SPREAD_LOWER=30), which common.sh copies into the sandbox config.

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

@test "check_spread.sh pushes one 【発生】 when the spread reaches the upper threshold" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 120 150.0 20 0.01
  atst_test_make_monitoring_csv A_MT4 60 150.1 70 0.01
  run bash "$BATS_TEST_DIRNAME/../check_spread.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(grep -c 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(grep -c '発生' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '5分間のスプレッド最高値: 70"' "$ATST_TEST_CURL_LOG"
  grep -q '^SPREAD_A_MT4,1,' "$HOME/.atst/alert_status"
}

@test "check_spread.sh pushes nothing without data from the last 5 minutes" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 600 150.0 70 0.01
  run bash "$BATS_TEST_DIRNAME/../check_spread.sh" A_MT4
  [ "$status" -eq 0 ]
  [ ! -e "$ATST_TEST_CURL_LOG" ] || [ "$(grep -c 'api.line.me' "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "S3: with alert 1 a spread maximum at the lower threshold sends one 【復帰】" {
  atst_test_make_mt A_MT4 MT4
  mkdir -p "$HOME/.atst"
  printf 'SPREAD_A_MT4,1,0\n' > "$HOME/.atst/alert_status"
  atst_test_make_monitoring_csv A_MT4 60 150.0 20 0.01
  run bash "$BATS_TEST_DIRNAME/../check_spread.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【復帰】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '^SPREAD_A_MT4,0,' "$HOME/.atst/alert_status"
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "S4: with alert 1 a spread maximum between the thresholds sends nothing" {
  atst_test_make_mt A_MT4 MT4
  mkdir -p "$HOME/.atst"
  printf 'SPREAD_A_MT4,1,0\n' > "$HOME/.atst/alert_status"
  atst_test_make_monitoring_csv A_MT4 60 150.0 45 0.01
  run bash "$BATS_TEST_DIRNAME/../check_spread.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  grep -q '^SPREAD_A_MT4,1,0$' "$HOME/.atst/alert_status"
}

@test "F1: a failed 【発生】 (500) is not recorded and is sent again (200) on the next run" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 60 150.0 70 0.01
  ATST_TEST_CURL_HTTP_CODE=500 run bash "$BATS_TEST_DIRNAME/../check_spread.sh" A_MT4
  [ "$(atst_test_push_count)" -eq 1 ]
  [ ! -e "$HOME/.atst/alert_status" ] || [ "$(grep -c '^SPREAD_' "$HOME/.atst/alert_status")" -eq 0 ]
  [ -e "$HOME/.atst/line_error.log" ]
  run bash "$BATS_TEST_DIRNAME/../check_spread.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -q '^SPREAD_A_MT4,1,' "$HOME/.atst/alert_status"
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}
