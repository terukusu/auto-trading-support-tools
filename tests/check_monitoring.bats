#!/usr/bin/env bats
# check_monitoring.sh: alert when the monitoring csv is missing while MetaTrader runs or stops being
# updated, ignoring a half-written last line (PR #77).

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

push_count() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep -c 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

# A complete line from 10 seconds ago, then a line the EA is still writing (only the first digits
# of the timestamp so far, no newline).
make_csv_with_half_line() {
  local now
  now=$(date +%s)
  atst_test_make_monitoring_csv A_MT4 10 150.0 10 0.01
  printf '%s' "${now:0:5}" >> "$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
}

@test "M1: no csv and MetaTrader not running sends nothing" {
  atst_test_make_mt ATSTTEST_MT4 MT4
  run bash "$BATS_TEST_DIRNAME/../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
  [ ! -e "$HOME/.atst/alert_status" ] || ! grep -q '^MONITORING_ATSTTEST_MT4,' "$HOME/.atst/alert_status"
}

@test "M2: no csv while MetaTrader runs sends one 【発生】 and only once" {
  atst_test_make_mt ATSTTEST_MT4 MT4
  atst_test_set_config ATST_MONITORING_THRESHOLD 1
  ATST_TEST_FAKE_PID=$(atst_test_fake_mt_process ATSTTEST_MT4)
  # ps reports the elapsed time in whole seconds; let it reach the threshold (1).
  sleep 2
  run bash "$BATS_TEST_DIRNAME/../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q 'モニタリングデータがありません' "$ATST_TEST_CURL_LOG"
  grep -q '【発生】' "$ATST_TEST_CURL_LOG"
  grep -q '^MONITORING_ATSTTEST_MT4,1,' "$HOME/.atst/alert_status"
  run bash "$BATS_TEST_DIRNAME/../check_monitoring.sh" ATSTTEST_MT4
  [ "$(push_count)" -eq 1 ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "M3: a half-written last line is ignored (no push while not alerting)" {
  atst_test_make_mt A_MT4 MT4
  make_csv_with_half_line
  run bash "$BATS_TEST_DIRNAME/../check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
}

@test "M3: a half-written last line with alert 1 sends one 【復帰】" {
  atst_test_make_mt A_MT4 MT4
  make_csv_with_half_line
  mkdir -p "$HOME/.atst"
  printf 'MONITORING_A_MT4,1,0\n' > "$HOME/.atst/alert_status"
  run bash "$BATS_TEST_DIRNAME/../check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q '【復帰】' "$ATST_TEST_CURL_LOG"
  grep -q '^MONITORING_A_MT4,0,' "$HOME/.atst/alert_status"
}

@test "M4: a stale last line sends one 【発生】 not updated" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  run bash "$BATS_TEST_DIRNAME/../check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q '更新されていません' "$ATST_TEST_CURL_LOG"
  grep -q '^MONITORING_A_MT4,1,' "$HOME/.atst/alert_status"
}
