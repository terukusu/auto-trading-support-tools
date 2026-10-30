#!/usr/bin/env bats
# check_daily.sh (#135): a config without ATST_IMAGE_REPORT_DESKTOP (written before the desktop image
# became opt-in) gets a one-time LINE notice through atst_update_alert (IMAGE_REPORT_DEFAULT_CHANGED).
# CD-11 and later (#136): LINE_QUOTA in alert_status (read by heartbeat.sh) and the line about an unset
# external monitor in the report.
# apt is a stub in the sandbox; LINE goes to the curl stub. The key and the LINE token are dummies.

load test_helper

setup() {
  atst_test_setup_sandbox
  # a value in the developer's environment must not leak in (the config is the input)
  unset ATST_IMAGE_REPORT_DESKTOP ATST_TEST_CURL_HTTP_CODE_SEQ
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  atst_test_stub_script "$ATST_TEST_SANDBOX/bin" apt record
  # #143: a fixed day before the deadline and a new-style crontab, never the developer's crontab.
  atst_test_stub_date "$ATST_TEST_SANDBOX/bin" 2026-11-01
  printf '#!/bin/bash\n[ "$*" = -l ] || exit 1\necho "* * * * * check_all.sh"\n' > "$ATST_TEST_SANDBOX/bin/crontab"
  chmod 755 "$ATST_TEST_SANDBOX/bin/crontab"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
  hash -r
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

# ---- #136: LINE_QUOTA for heartbeat.sh and the line about the external monitor ----
# The quota API answers with one body for both calls (quota and consumption); value 200 is the limit.

HB_U=https://example.invalid/ping/abcd9876

quota_body() {
  export ATST_TEST_CURL_BODY="{\"type\":\"limited\",\"value\":200,\"totalUsage\":$1}"
}

# Number of LINE_QUOTA lines in alert_status matching the regex $1 (0 without the file).
quota_lines() {
  if [ -e "$HOME/.atst/alert_status" ]; then
    grep -c "$1" "$HOME/.atst/alert_status"
  else
    echo 0
  fi
}

# The push lines of the daily report.
daily_push() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | grep '稼働OK'
  fi
}

# heartbeat.sh after the daily run, with the dummy URL.
run_heartbeat() {
  unset ATST_TEST_CURL_BODY
  atst_test_set_config ATST_HEARTBEAT_URL "$HB_U"
  run bash "$BATS_TEST_DIRNAME/../heartbeat.sh"
}

hb_fail_lines() {
  grep -c 'abcd9876/fail"' "$ATST_TEST_CURL_LOG"
}

@test "CD-11: 85% of the quota records LINE_QUOTA,1 and the next heartbeat is /fail (AC10)" {
  atst_test_set_config ATST_DAILY_REPORT 1
  quota_body 170
  run_daily
  [ "$status" -eq 0 ]
  [ "$(quota_lines '^LINE_QUOTA,1,[0-9]*$')" -eq 1 ]
  run_heartbeat
  [ "$status" -eq 0 ]
  [ "$(hb_fail_lines)" -eq 1 ]
  [[ "$(grep 'abcd9876/fail"' "$ATST_TEST_CURL_LOG")" == *'data-raw = "LINE_QUOTA"' ]]
}

@test "CD-12: the bound is the same as the warning: 160/200 is 1, 159/200 is 0" {
  atst_test_set_config ATST_DAILY_REPORT 1
  quota_body 160
  run_daily
  [ "$(quota_lines '^LINE_QUOTA,1,')" -eq 1 ]
  quota_body 159
  run_daily
  [ "$(quota_lines '^LINE_QUOTA,0,')" -eq 1 ]
  [ "$(quota_lines '^LINE_QUOTA,1,')" -eq 0 ]
}

@test "CD-13: below 80% turns LINE_QUOTA back to 0 and the next heartbeat is a ping (AC10)" {
  atst_test_set_config ATST_DAILY_REPORT 1
  printf 'LINE_QUOTA,1,1700000000\n' > "$HOME/.atst/alert_status"
  quota_body 10
  run_daily
  [ "$status" -eq 0 ]
  [ "$(quota_lines '^LINE_QUOTA,0,')" -eq 1 ]
  [ "$(quota_lines '^LINE_QUOTA,1')" -eq 0 ]
  run_heartbeat
  [ "$(hb_fail_lines)" -eq 0 ]
  [ "$(grep abcd9876 "$ATST_TEST_CURL_LOG" | grep -vc '/fail')" -eq 1 ]
}

@test "CD-14: a plan without a limit records LINE_QUOTA,0" {
  atst_test_set_config ATST_DAILY_REPORT 1
  export ATST_TEST_CURL_BODY='{"type":"none","totalUsage":10}'
  run_daily
  [ "$(quota_lines '^LINE_QUOTA,0,')" -eq 1 ]
  [ "$(quota_lines '^LINE_QUOTA,1')" -eq 0 ]
}

@test "CD-15: when the quota cannot be read LINE_QUOTA is neither changed nor created" {
  atst_test_set_config ATST_DAILY_REPORT 1
  printf 'LINE_QUOTA,1,1700000000\n' > "$HOME/.atst/alert_status"
  run_daily
  [ "$(quota_lines '^LINE_QUOTA,1,1700000000$')" -eq 1 ]
  rm -f "$HOME/.atst/alert_status"
  run_daily
  [ "$(quota_lines '^LINE_QUOTA')" -eq 0 ]
}

@test "CD-16: LINE_QUOTA is written before the push (a failed push keeps it) and is not a notice of its own" {
  atst_test_set_config ATST_DAILY_REPORT 1
  quota_body 170
  export ATST_TEST_CURL_HTTP_CODE_SEQ="200 200 500"
  run_daily
  [ "$(quota_lines '^LINE_QUOTA,1,')" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "CD-17: a failed LINE_QUOTA write (empty ATST_ALERT_STATUS_FILE) still sends the report" {
  atst_test_set_config ATST_DAILY_REPORT 1
  atst_test_set_config ATST_ALERT_STATUS_FILE ''
  quota_body 170
  run_daily
  [ "$(daily_push | wc -l)" -eq 1 ]
}

@test "CD-18: without a heartbeat URL the report has the line, after the LINE count (AC20)" {
  atst_test_set_config ATST_DAILY_REPORT 1
  quota_body 10
  run_daily
  [ "$status" -eq 0 ]
  [ "$(daily_push | wc -l)" -eq 1 ]
  [[ "$(daily_push)" == *'LINE 送信数'*'外形監視: 未設定（推奨。setup_heartbeat.sh で設定）'* ]]
}

@test "CD-19: with a URL in the config or in .heartbeat_url there is no line and no URL (AC20, AC21)" {
  atst_test_set_config ATST_DAILY_REPORT 1
  atst_test_set_config ATST_HEARTBEAT_URL "$HB_U"
  quota_body 10
  run_daily
  [ "$(daily_push | wc -l)" -eq 1 ]
  [[ "$(daily_push)" != *'外形監視'* ]]
  [[ "$output" != *example.invalid* ]]
  [ "$(grep -c example.invalid "$ATST_TEST_CURL_LOG")" -eq 0 ]

  rm -f "$HOME/.atst/config" "$ATST_TEST_CURL_LOG"
  atst_test_set_config ATST_DAILY_REPORT 1
  printf '%s\n' "$HB_U" > "$HOME/.atst/.heartbeat_url"
  chmod 600 "$HOME/.atst/.heartbeat_url"
  run_daily
  [ "$(daily_push | wc -l)" -eq 1 ]
  [[ "$(daily_push)" != *'外形監視'* ]]
  [[ "$output" != *example.invalid* ]]
  [ "$(grep -c example.invalid "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "CD-20: with ATST_DAILY_REPORT=0 the line alone sends nothing (AC20)" {
  atst_test_set_config ATST_DAILY_REPORT 0
  quota_body 10
  run_daily
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "CD-21: with ATST_DAILY_REPORT=0 a quota warning is sent with the line" {
  atst_test_set_config ATST_DAILY_REPORT 0
  quota_body 170
  run_daily
  [ "$(atst_test_push_count)" -eq 1 ]
  [[ "$(daily_push)" == *'【注意】LINE の今月の送信数'* ]]
  [[ "$(daily_push)" == *'外形監視: 未設定'* ]]
}
