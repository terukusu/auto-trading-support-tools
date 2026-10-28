#!/usr/bin/env bats
# check_daily.sh (#135): a config without ATST_IMAGE_REPORT_DESKTOP (written before the desktop image
# became opt-in) gets a one-time LINE notice through atst_update_alert (IMAGE_REPORT_DEFAULT_CHANGED).
# apt is a stub in the sandbox; LINE goes to the curl stub. The key and the LINE token are dummies.

load test_helper

setup() {
  atst_test_setup_sandbox
  # a value in the developer's environment must not leak in (the config is the input)
  unset ATST_IMAGE_REPORT_DESKTOP ATST_TEST_CURL_HTTP_CODE_SEQ
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  atst_test_stub_script "$ATST_TEST_SANDBOX/bin" apt record
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
}

teardown() {
  atst_test_teardown_sandbox
}

# A config from before #135: the template without the ATST_IMAGE_REPORT_DESKTOP line.
old_config() {
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_IMAGE_REPORT_DESKTOP=/d' "$HOME/.atst/config"
}

# Number of pushes carrying the notice.
notice_count() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | grep -c 'デスクトップ画像'
  else
    echo 0
  fi
}

# Number of IMAGE_REPORT_DEFAULT_CHANGED lines in alert_status (0 without the file).
recorded() {
  if [ -e "$HOME/.atst/alert_status" ]; then
    grep -c '^IMAGE_REPORT_DEFAULT_CHANGED,' "$HOME/.atst/alert_status"
  else
    echo 0
  fi
}

stub_calls() {
  if [ -e "$ATST_TEST_SANDBOX/calls.log" ]; then
    grep -c "^$1 " "$ATST_TEST_SANDBOX/calls.log"
  else
    echo 0
  fi
}

run_daily() {
  run bash "$BATS_TEST_DIRNAME/../check_daily.sh"
}

@test "CD-1: an old config gets the notice once over two runs and it is recorded" {
  local n1
  old_config
  run_daily
  [ "$status" -eq 0 ]
  [ "$(notice_count)" -eq 1 ]
  [ "$(grep -c '^IMAGE_REPORT_DEFAULT_CHANGED,1,[0-9]*$' "$HOME/.atst/alert_status")" -eq 1 ]
  n1=$(atst_test_push_count)
  run_daily
  [ "$status" -eq 0 ]
  [ "$(( $(atst_test_push_count) - n1 ))" -eq 1 ]
  [ "$(notice_count)" -eq 1 ]
  [ "$(stub_calls apt)" -ge 1 ]
}

@test "CD-2: a failed notice push is not recorded and is sent again on the next run" {
  local c1
  old_config
  # curl calls: quota x2, daily push, notice push (500)
  export ATST_TEST_CURL_HTTP_CODE_SEQ="200 200 200 500"
  run_daily
  unset ATST_TEST_CURL_HTTP_CODE_SEQ
  [ "$(recorded)" -eq 0 ]
  grep -q 'http=500' "$HOME/.atst/line_error.log"
  c1=$(notice_count)
  [ "$c1" -eq 1 ]
  run_daily
  [ "$status" -eq 0 ]
  [ "$(notice_count)" -eq $((c1 + 1)) ]
  grep -q '^IMAGE_REPORT_DEFAULT_CHANGED,1,' "$HOME/.atst/alert_status"
}

@test "CD-3/CD-10: the template config (with the line) never gets the notice and exits 0" {
  atst_test_set_config ATST_DAILY_REPORT 1
  grep -q '^ATST_IMAGE_REPORT_DESKTOP=0$' "$HOME/.atst/config"
  run_daily
  [ "$status" -eq 0 ]
  run_daily
  [ "$status" -eq 0 ]
  [ "$(notice_count)" -eq 0 ]
  [ "$(recorded)" -eq 0 ]
}

@test "CD-4: ATST_IMAGE_REPORT_TERM=0 gets no notice" {
  old_config
  atst_test_set_config ATST_IMAGE_REPORT_TERM 0
  run_daily
  [ "$status" -eq 0 ]
  [ "$(notice_count)" -eq 0 ]
  [ "$(recorded)" -eq 0 ]
}

@test "CD-5: the notice is sent even with ATST_DAILY_REPORT=0" {
  old_config
  atst_test_set_config ATST_DAILY_REPORT 0
  run_daily
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(notice_count)" -eq 1 ]
  [ "$(grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | grep -c '稼働OK')" -eq 0 ]
}

@test "CD-6: adding the line after the notice sends no recovery notice and keeps the record" {
  local n1
  old_config
  run_daily
  [ "$status" -eq 0 ]
  [ "$(notice_count)" -eq 1 ]
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 0
  n1=$(atst_test_push_count)
  run_daily
  [ "$status" -eq 0 ]
  [ "$(( $(atst_test_push_count) - n1 ))" -eq 1 ]
  grep -q '^IMAGE_REPORT_DEFAULT_CHANGED,1,' "$HOME/.atst/alert_status"
  [ "$(grep -c '^IMAGE_REPORT_DEFAULT_CHANGED,0' "$HOME/.atst/alert_status")" -eq 0 ]
}

@test "CD-7: an empty ATST_IMAGE_REPORT_DESKTOP= line counts as set" {
  old_config
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP ''
  run_daily
  [ "$status" -eq 0 ]
  [ "$(notice_count)" -eq 0 ]
}

@test "CD-8: the notice text has the required phrases and no secret or path" {
  local line
  old_config
  atst_test_set_config ATST_LINE_TOKEN dummytok135
  printf 'secretkey123\n' > "$HOME/.atst/.imgbb_key"
  run_daily
  [ "$status" -eq 0 ]
  line=$(grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | grep 'デスクトップ画像')
  [ -n "$line" ]
  [[ "$line" == *'デスクトップ画像の通知は既定 OFF'* ]]
  [[ "$line" == *'口座番号・残高'* ]]
  [[ "$line" == *'setup_imgbb.sh'* ]]
  [[ "$line" == *'ATST_IMAGE_REPORT_DESKTOP=1'* ]]
  [[ "$line" == *'1 度だけ'* ]]
  [[ "$line" != *dummytok135* ]]
  [[ "$line" != *secretkey123* ]]
  [[ "$line" != *"$ATST_TEST_SANDBOX"* ]]
  [ "$(grep -c 'dummytok135\|secretkey123' "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "CD-9: an empty ATST_ALERT_STATUS_FILE sends no notice, logs no_alert_status and exits 1" {
  old_config
  atst_test_set_config ATST_ALERT_STATUS_FILE ''
  run_daily
  [ "$status" -eq 1 ]
  [ "$(notice_count)" -eq 0 ]
  grep -q 'http=no_alert_status' "$HOME/.atst/line_error.log"
}
