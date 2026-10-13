#!/usr/bin/env bats
# atst_alert_transition / atst_update_alert (common.sh): the transition table without side effects,
# and one push per due message with the state recorded only after a successful send (#92).

load test_helper

setup() {
  atst_test_setup_sandbox
  atst_test_source_common
}

teardown() {
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
