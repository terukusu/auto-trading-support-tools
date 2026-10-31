#!/usr/bin/env bats
# check_monitoring.sh: alert when the monitoring csv is missing while MetaTrader runs or stops being
# updated, ignoring a half-written last line (PR #77).

load ../test_helper

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
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
  [ ! -e "$HOME/.atst/alert_status" ] || ! grep -q '^MONITORING_ATSTTEST_MT4,' "$HOME/.atst/alert_status"
}

@test "M2: no csv while MetaTrader runs sends one 【発生】 and only once" {
  atst_test_make_mt ATSTTEST_MT4 MT4
  atst_test_set_config ATST_MONITORING_THRESHOLD 1
  export ATST_PROC_ROOT=/proc
  ATST_TEST_FAKE_PID=$(atst_test_fake_mt_process ATSTTEST_MT4)
  # ps reports the elapsed time in whole seconds; let it reach the threshold (1).
  sleep 2
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q 'モニタリングデータがありません' "$ATST_TEST_CURL_LOG"
  grep -q '【発生】' "$ATST_TEST_CURL_LOG"
  grep -q '^MONITORING_ATSTTEST_MT4,1,' "$HOME/.atst/alert_status"
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$(push_count)" -eq 1 ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "M3: a half-written last line is ignored (no push while not alerting)" {
  atst_test_make_mt A_MT4 MT4
  make_csv_with_half_line
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
}

@test "M3: a half-written last line with alert 1 sends one 【復帰】" {
  atst_test_make_mt A_MT4 MT4
  make_csv_with_half_line
  mkdir -p "$HOME/.atst"
  printf 'MONITORING_A_MT4,1,0\n' > "$HOME/.atst/alert_status"
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q '【復帰】' "$ATST_TEST_CURL_LOG"
  grep -q '^MONITORING_A_MT4,0,' "$HOME/.atst/alert_status"
}

@test "M4: a stale last line sends one 【発生】 not updated" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q '更新されていません' "$ATST_TEST_CURL_LOG"
  grep -q '^MONITORING_A_MT4,1,' "$HOME/.atst/alert_status"
}

# --- MONITORING_AUTO_ATTACH_<MT> (ATST_AUTO_ATTACH_EA=1, #133) ---

ma_enable() {
  atst_test_set_config ATST_AUTO_ATTACH_EA 1
  atst_test_set_config ATST_AUTO_ATTACH_SYMBOL EURUSD
  atst_test_set_config ATST_AUTO_ATTACH_PERIOD M5
}

# Pushes of the new key (their text has 自動配置), 0 without a log.
ma_count() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep -c "${1:-自動配置}" "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

# Returns 0 when alert_status has no MONITORING_AUTO_ATTACH_ line (a function, so that a failure stops
# the test even inside a loop, unlike a bare "! grep").
ma_no_new_key() {
  [ ! -e "$HOME/.atst/alert_status" ] || ! grep -q '^MONITORING_AUTO_ATTACH_' "$HOME/.atst/alert_status"
}

# MetaTrader ATSTTEST_MT4 running for 2 seconds or more with threshold 1 (as M2).
ma_running() {
  atst_test_make_mt ATSTTEST_MT4 MT4
  atst_test_set_config ATST_MONITORING_THRESHOLD "${1:-1}"
  export ATST_PROC_ROOT=/proc
  ATST_TEST_FAKE_PID=$(atst_test_fake_mt_process ATSTTEST_MT4)
}

@test "MA-1: enabled, no csv while MetaTrader runs: one 【発生】 of the new key besides the old one, only once" {
  local l
  ma_running
  ma_enable
  sleep 2
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 2 ]
  [ "$(ma_count '【発生】.*自動配置')" -eq 1 ]
  [ "$(ma_count 'モニタリングデータがありません')" -eq 1 ]
  grep -q '^MONITORING_AUTO_ATTACH_ATSTTEST_MT4,1,' "$HOME/.atst/alert_status"
  grep -q '^MONITORING_ATSTTEST_MT4,1,' "$HOME/.atst/alert_status"
  l=$(grep '自動配置' "$ATST_TEST_CURL_LOG")
  [[ $l == *drive_c/atst/startup_atsttest_mt4.ini* ]]
  [[ $l == *atst*startup_atsttest_mt4.ini\)* ]]
  [[ $l == *C:* ]]
  [[ $l == *'~/.atst/wine_atsttest_mt4.log'* ]]
  [[ $l == *'doctor.sh の auto_attach'* ]]
  [[ $l != *"$HOME"* ]]
  [[ $l != *"$WINEPREFIX"* ]]
  [[ $l != *Z:* ]]
  [[ $l != *EURUSD* ]]
  [[ $l != *'~/.atst/startup_'* ]]
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$(push_count)" -eq 2 ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "MA-2: after MA-1 a data line written since the start sends one 【復帰】 of the new key" {
  ma_running
  ma_enable
  sleep 2
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  grep -q '^MONITORING_AUTO_ATTACH_ATSTTEST_MT4,1,' "$HOME/.atst/alert_status"
  atst_test_make_monitoring_csv ATSTTEST_MT4 0 150.0 10 0.01
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(ma_count '【復帰】ATSTTEST_MT4 の自動配置 (ATST_AUTO_ATTACH_EA=1) でモニタリングデータが出るようになりました')" -eq 1 ]
  grep -q '^MONITORING_AUTO_ATTACH_ATSTTEST_MT4,0,' "$HOME/.atst/alert_status"
}

@test "MA-3: ATST_AUTO_ATTACH_EA=0 or no line: the new key sends and records nothing" {
  local c
  ma_running
  for c in zero noline; do
    rm -f "$ATST_TEST_CURL_LOG" "$HOME/.atst/alert_status"
    case $c in
      zero) atst_test_set_config ATST_AUTO_ATTACH_EA 0 ;;
      noline) sed -i '/^ATST_AUTO_ATTACH_EA=/d' "$HOME/.atst/config" ;;
    esac
    sleep 2
    run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
    [ "$status" -eq 0 ]
    [ "$(push_count)" -eq 1 ]
    [ "$(ma_count 'モニタリングデータがありません')" -eq 1 ]
    [ "$(ma_count)" -eq 0 ]
    [ -e "$HOME/.atst/alert_status" ]
    ma_no_new_key
  done
}

@test "MA-4: only lines older than the start of MetaTrader: the new key fires (with the old key)" {
  ma_running
  ma_enable
  atst_test_make_monitoring_csv ATSTTEST_MT4 500 150.0 10 0.01
  sleep 2
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(ma_count '【発生】.*自動配置')" -eq 1 ]
  grep -q '^MONITORING_AUTO_ATTACH_ATSTTEST_MT4,1,' "$HOME/.atst/alert_status"
  grep -q '^MONITORING_ATSTTEST_MT4,1,' "$HOME/.atst/alert_status"
  [ "$(ma_count '更新されていません')" -eq 1 ]
}

@test "MA-5: a line written since the start of MetaTrader: the new key does nothing" {
  ma_running
  ma_enable
  sleep 2
  atst_test_make_monitoring_csv ATSTTEST_MT4 0 150.0 10 0.01
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(ma_count)" -eq 0 ]
  ma_no_new_key
}

@test "MA-6: enabled but MetaTrader not running: nothing is sent or recorded" {
  atst_test_make_mt ATSTTEST_MT4 MT4
  atst_test_set_config ATST_MONITORING_THRESHOLD 1
  ma_enable
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
  ma_no_new_key
}

@test "MA-7: the new key at 1 and ATST_AUTO_ATTACH_EA=0: one 【復帰】 that ends the check, only once" {
  atst_test_make_mt A_MT4 MT4
  atst_test_set_config ATST_AUTO_ATTACH_EA 0
  atst_test_make_monitoring_csv A_MT4 0 150.0 10 0.01
  printf 'MONITORING_AUTO_ATTACH_A_MT4,1,0\n' > "$HOME/.atst/alert_status"
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  [ "$(ma_count '【復帰】A_MT4 の自動配置の確認を終了しました (ATST_AUTO_ATTACH_EA が 1 ではありません)')" -eq 1 ]
  grep -q '^MONITORING_AUTO_ATTACH_A_MT4,0,' "$HOME/.atst/alert_status"
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" A_MT4
  [ "$(push_count)" -eq 1 ]
}

@test "MA-8: enabled, MetaTrader just started (under the threshold): the new key does nothing" {
  ma_running 600
  ma_enable
  sleep 1
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 0 ]
  ma_no_new_key
}

@test "M-PN: the 【発生】 of no data (no csv while MetaTrader runs) carries no positions note (#177)" {
  atst_test_make_mt ATSTTEST_MT4 MT4
  atst_test_set_config ATST_MONITORING_THRESHOLD 1
  export ATST_PROC_ROOT=/proc
  ATST_TEST_FAKE_PID=$(atst_test_fake_mt_process ATSTTEST_MT4)
  sleep 2
  run bash "$BATS_TEST_DIRNAME/../../check_monitoring.sh" ATSTTEST_MT4
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  grep -q 'モニタリングデータがありません' "$ATST_TEST_CURL_LOG"
  [ "$(grep -c '建玉' "$ATST_TEST_CURL_LOG")" -eq 0 ]
}
