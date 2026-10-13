#!/usr/bin/env bats
# check_process.sh: alert when a MetaTrader process is not running (do_check) and when a TARGET
# name matches no installed MetaTrader (check_target_found).

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  local k
  case "${ATST_TEST_FAKE_PID:-}" in
    ''|*[!0-9]*) ;;
    *)
      kill "$ATST_TEST_FAKE_PID" 2>/dev/null
      for k in $(seq 1 10); do
        kill -0 "$ATST_TEST_FAKE_PID" 2>/dev/null || break
        sleep 0.1
      done
      ;;
  esac
  atst_test_teardown_sandbox
}

set_status() {
  mkdir -p "$HOME/.atst"
  printf '%s\n' "$1" > "$HOME/.atst/alert_status"
}

no_bearer() {
  [ ! -e "$ATST_TEST_CURL_LOG" ] || [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

no_line() {
  [ ! -e "$HOME/.atst/alert_status" ] || [ "$(grep -c "^$1" "$HOME/.atst/alert_status")" -eq 0 ]
}

@test "P1: an installed MetaTrader without a process sends one 【発生】 and records PROCESS_<NAME>,1" {
  atst_test_make_mt A_MT4 MT4
  run bash "$BATS_TEST_DIRNAME/../check_process.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【発生】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q 'MetaTraderプロセスが動作していません: A_MT4' "$ATST_TEST_CURL_LOG"
  grep -q '^PROCESS_A_MT4,1,' "$HOME/.atst/alert_status"
  no_line TARGET_
  no_bearer
}

@test "P2: a running (fake) process with PROCESS_<NAME>,1 sends one 【復帰】 and records 0" {
  atst_test_make_mt ATSTTEST_MT4 MT4
  set_status 'PROCESS_ATSTTEST_MT4,1,0'
  ATST_TEST_FAKE_PID=$(atst_test_fake_mt_process ATSTTEST_MT4)
  run bash "$BATS_TEST_DIRNAME/../check_process.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【復帰】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q 'MetaTraderプロセスが再開しました: ATSTTEST_MT4' "$ATST_TEST_CURL_LOG"
  grep -q '^PROCESS_ATSTTEST_MT4,0,' "$HOME/.atst/alert_status"
  no_bearer
}

@test "T1: a TARGET matching no MetaTrader sends one 【発生】 with a normalized key, only once" {
  atst_test_make_mt A_MT4 MT4
  run bash "$BATS_TEST_DIRNAME/../check_process.sh" "No Such-MT"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【発生】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '監視対象のMetaTraderが見つかりません' "$ATST_TEST_CURL_LOG"
  grep -q '^TARGET_No_Such_MT,1,' "$HOME/.atst/alert_status"
  run bash "$BATS_TEST_DIRNAME/../check_process.sh" "No Such-MT"
  [ "$(atst_test_push_count)" -eq 1 ]
  no_bearer
}

@test "T2: a TARGET found again with TARGET_<NAME>,1 sends one 【復帰】 and no PROCESS push" {
  atst_test_make_mt ATSTTEST_MT4 MT4
  set_status 'TARGET_ATSTTEST_MT4,1,0'
  ATST_TEST_FAKE_PID=$(atst_test_fake_mt_process ATSTTEST_MT4)
  run bash "$BATS_TEST_DIRNAME/../check_process.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '【復帰】' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -q '監視対象のMetaTraderが見つかりました: ATSTTEST_MT4' "$ATST_TEST_CURL_LOG"
  grep -q '^TARGET_ATSTTEST_MT4,0,' "$HOME/.atst/alert_status"
  no_line PROCESS_
  no_bearer
}

@test "T3: a failed TARGET 【発生】 (500) is not recorded and is sent again on the next run" {
  atst_test_make_mt A_MT4 MT4
  ATST_TEST_CURL_HTTP_CODE=500 run bash "$BATS_TEST_DIRNAME/../check_process.sh" "No Such-MT"
  [ "$(atst_test_push_count)" -eq 1 ]
  no_line TARGET_
  run bash "$BATS_TEST_DIRNAME/../check_process.sh" "No Such-MT"
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -q '^TARGET_No_Such_MT,1,' "$HOME/.atst/alert_status"
  no_bearer
}
