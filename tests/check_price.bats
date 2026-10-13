#!/usr/bin/env bats
# check_price.sh: alert on the 10-minute bid range in pips.
# Relies on the default thresholds of templates/config (ATST_THRESHOLD_PRICE_UPPER=100,
# ATST_THRESHOLD_PRICE_LOWER=50), which common.sh copies into the sandbox config.

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

@test "check_price.sh pushes one 【発生】 when the 10-minute range reaches the upper threshold" {
  command -v bc >/dev/null || skip "bc not installed"
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  atst_test_make_monitoring_csv A_MT4 60 151.5 10 0.01
  run bash "$BATS_TEST_DIRNAME/../check_price.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(grep -c 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(grep -c '発生' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '高値:151.5, 安値:150, 10分値幅: 150 pips' "$ATST_TEST_CURL_LOG"
  grep -q '^PRICE_A_MT4,1,' "$HOME/.atst/alert_status"
}

@test "check_price.sh pushes nothing without data from the last 10 minutes" {
  command -v bc >/dev/null || skip "bc not installed"
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 800 150.0 10 0.01
  atst_test_make_monitoring_csv A_MT4 700 151.5 10 0.01
  run bash "$BATS_TEST_DIRNAME/../check_price.sh" A_MT4
  [ "$status" -eq 0 ]
  [ ! -e "$ATST_TEST_CURL_LOG" ] || [ "$(grep -c 'api.line.me' "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "R1: with UPPER < LOWER and no state, a range matching both sends one 【発生】" {
  command -v bc >/dev/null || skip "bc not installed"
  atst_test_make_mt A_MT4 MT4
  atst_test_set_config ATST_THRESHOLD_PRICE_LOWER 200
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  atst_test_make_monitoring_csv A_MT4 60 151.5 10 0.01
  run bash "$BATS_TEST_DIRNAME/../check_price.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【発生】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '^PRICE_A_MT4,1,' "$HOME/.atst/alert_status"
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "R2: with UPPER < LOWER and alert 1, a range matching both sends one 【復帰】" {
  command -v bc >/dev/null || skip "bc not installed"
  atst_test_make_mt A_MT4 MT4
  atst_test_set_config ATST_THRESHOLD_PRICE_LOWER 200
  printf 'PRICE_A_MT4,1,0\n' > "$HOME/.atst/alert_status"
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  atst_test_make_monitoring_csv A_MT4 60 151.5 10 0.01
  run bash "$BATS_TEST_DIRNAME/../check_price.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【復帰】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '^PRICE_A_MT4,0,' "$HOME/.atst/alert_status"
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}
