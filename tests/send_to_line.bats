#!/usr/bin/env bats
# Fixture check: send_to_line.sh runs against the curl stub (not a regression test).

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

@test "send_to_line.sh posts to the push API through the curl stub" {
  [ "$(command -v curl)" = "$BATS_TEST_DIRNAME/stubs/curl" ]
  run bash -c 'echo hello | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q hello "$ATST_TEST_CURL_LOG"
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ ! -e "$HOME/.atst/line_error.log" ]
}

@test "send_to_line.sh exits 2 and logs the error on HTTP 400" {
  [ "$(command -v curl)" = "$BATS_TEST_DIRNAME/stubs/curl" ]
  export ATST_TEST_CURL_HTTP_CODE=400
  run bash -c 'echo hello | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
  [ "$status" -eq 2 ]
  [ -f "$HOME/.atst/line_error.log" ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}
