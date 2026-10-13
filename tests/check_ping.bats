#!/usr/bin/env bats
# check_ping.sh: alert on the ping of the latest complete monitoring line (6th field, microseconds).
# Relies on the default thresholds of templates/config (ATST_THRESHOLD_PING_UPPER=600000,
# ATST_THRESHOLD_PING_LOWER=300000), which common.sh copies into the sandbox config.

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

set_status() {
  mkdir -p "$HOME/.atst"
  printf '%s\n' "$1" > "$HOME/.atst/alert_status"
}

no_bearer() {
  [ ! -e "$ATST_TEST_CURL_LOG" ] || [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "G1: a ping at the upper threshold sends one 【発生】 and records PING_<NAME>,1" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 10 150.0 10 0.01 600000
  run bash "$BATS_TEST_DIRNAME/../check_ping.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【発生】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '現在のPing: 600ms' "$ATST_TEST_CURL_LOG"
  grep -q '^PING_A_MT4,1,' "$HOME/.atst/alert_status"
  no_bearer
}

@test "G2: with alert 1 a ping between the thresholds sends nothing and keeps the state" {
  atst_test_make_mt A_MT4 MT4
  set_status 'PING_A_MT4,1,0'
  atst_test_make_monitoring_csv A_MT4 10 150.0 10 0.01 450000
  run bash "$BATS_TEST_DIRNAME/../check_ping.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  grep -q '^PING_A_MT4,1,0$' "$HOME/.atst/alert_status"
  no_bearer
}

@test "G3: with alert 1 a ping at the lower threshold sends one 【復帰】 and records 0" {
  atst_test_make_mt A_MT4 MT4
  set_status 'PING_A_MT4,1,0'
  atst_test_make_monitoring_csv A_MT4 10 150.0 10 0.01 300000
  run bash "$BATS_TEST_DIRNAME/../check_ping.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【復帰】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '^PING_A_MT4,0,' "$HOME/.atst/alert_status"
  no_bearer
}

@test "G4: with UPPER <= LOWER and no state, a ping matching both sends one 【発生】" {
  atst_test_make_mt A_MT4 MT4
  atst_test_set_config ATST_THRESHOLD_PING_UPPER 300000
  atst_test_set_config ATST_THRESHOLD_PING_LOWER 600000
  atst_test_make_monitoring_csv A_MT4 10 150.0 10 0.01 450000
  run bash "$BATS_TEST_DIRNAME/../check_ping.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【発生】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '^PING_A_MT4,1,' "$HOME/.atst/alert_status"
  no_bearer
}

@test "G5: with UPPER <= LOWER and alert 1, a ping matching both sends one 【復帰】" {
  atst_test_make_mt A_MT4 MT4
  atst_test_set_config ATST_THRESHOLD_PING_UPPER 300000
  atst_test_set_config ATST_THRESHOLD_PING_LOWER 600000
  set_status 'PING_A_MT4,1,0'
  atst_test_make_monitoring_csv A_MT4 10 150.0 10 0.01 450000
  run bash "$BATS_TEST_DIRNAME/../check_ping.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【復帰】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '^PING_A_MT4,0,' "$HOME/.atst/alert_status"
  no_bearer
}
