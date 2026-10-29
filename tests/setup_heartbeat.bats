#!/usr/bin/env bats
# setup_heartbeat.sh (#136): saves the heartbeat URL read from stdin to ~/.atst/.heartbeat_url (600)
# and sends one test ping (GET, never /fail); an empty line removes the file, EOF and a bad value change
# nothing. The URL is a dummy under example.invalid and goes to the curl stub only.

load test_helper

U=https://example.invalid/ping/abcd9876
UF=https://example.invalid/file/yyyy2222

setup() {
  atst_test_setup_sandbox
  unset ATST_TEST_CURL_BODY ATST_TEST_CURL_HTTP_CODE ATST_TEST_CURL_HTTP_CODE_SEQ ATST_TEST_CURL_EXIT \
    ATST_TEST_CURL_FILE
  mkdir -p "$HOME/.atst"
  S=$BATS_TEST_DIRNAME/../setup_heartbeat.sh
  F=$HOME/.atst/.heartbeat_url
  LOG=$ATST_TEST_CURL_LOG
}

teardown() {
  chmod -R u+rwX "$ATST_TEST_SANDBOX" 2>/dev/null
  atst_test_teardown_sandbox
}

log_lines() {
  if [ -e "$LOG" ]; then
    wc -l < "$LOG"
  else
    echo 0
  fi
}

# The output never shows the URL or a part of it (AC17, AC21).
no_url_shown() {
  [[ "$output" != *example.invalid* ]] || return 1
  [[ "$output" != */ping/* ]] || return 1
  [[ "$output" != *abcd* ]] || return 1
  [[ "$output" != *yyyy* ]] || return 1
  if [ -e "$LOG" ]; then
    [ "$(sed 's/ | .*//' "$LOG" | grep -c example.invalid)" -eq 0 ] || return 1
  fi
}

put_file() {
  printf '%s\n' "$1" > "$F"
  chmod 600 "$F"
}

@test "SH-1: a valid URL is saved 600 and one test ping (GET) is sent (AC13)" {
  run bash "$S" <<< "$U"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$F")" = 600 ]
  [ "$(cat "$F")" = "$U" ]
  [ "$(wc -l < "$F")" -eq 1 ]
  [ "$(log_lines)" -eq 1 ]
  [[ "$(cat "$LOG")" == *" | url = \"$U\"" ]]
  [ "$(grep -c '/fail\|data' "$LOG")" -eq 0 ]
  [[ "$(sed 's/ | .*//' "$LOG")" == *"-w %{http_code}"* ]]
  [[ "$(sed 's/ | .*//' "$LOG")" == *"--max-time 10"* ]]
  [[ "$output" == *'****9876'* ]]
  [[ "$output" == *'HTTP 200'* ]]
  [[ "$output" == *'成功'* ]]
  no_url_shown
}

@test "SH-2: spaces around the input are removed" {
  run bash "$S" <<< "   $U  "
  [ "$status" -eq 0 ]
  [ "$(cat "$F")" = "$U" ]
  no_url_shown
}

@test "SH-3: an existing file (644) is overwritten and made 600" {
  printf '%s\n' "$UF" > "$F"
  chmod 644 "$F"
  run bash "$S" <<< "$U"
  [ "$status" -eq 0 ]
  [ "$(cat "$F")" = "$U" ]
  [ "$(stat -c %a "$F")" = 600 ]
  no_url_shown
}

@test "SH-4: HTTP 404 fails with exit 1 and the file is kept (AC14)" {
  export ATST_TEST_CURL_HTTP_CODE=404
  run bash "$S" <<< "$U"
  [ "$status" -eq 1 ]
  [[ "$output" == *404* ]]
  [[ "$output" == *'失敗'* ]]
  [ "$(cat "$F")" = "$U" ]
  [ "$(stat -c %a "$F")" = 600 ]
  no_url_shown
}

@test "SH-5: a curl exit code other than 0 fails even with HTTP 200" {
  export ATST_TEST_CURL_EXIT=6
  run bash "$S" <<< "$U"
  [ "$status" -eq 1 ]
  [[ "$output" != *'成功'* ]]
  [[ "$output" == *'失敗'* ]]
  [ "$(cat "$F")" = "$U" ]
  no_url_shown
}

@test "SH-6: only a 3-digit 2xx code is success (abc -> 000, 301 fails, 204 succeeds)" {
  export ATST_TEST_CURL_HTTP_CODE=abc
  run bash "$S" <<< "$U"
  [ "$status" -eq 1 ]
  [[ "$output" == *'HTTP 000'* ]]
  export ATST_TEST_CURL_HTTP_CODE=301
  run bash "$S" <<< "$U"
  [ "$status" -eq 1 ]
  export ATST_TEST_CURL_HTTP_CODE=204
  run bash "$S" <<< "$U"
  [ "$status" -eq 0 ]
  no_url_shown
}

@test "SH-7: an empty line removes the file without curl and exits 0 (AC15)" {
  run bash "$S" <<< "$U"
  [ "$status" -eq 0 ]
  run bash "$S" <<< ""
  [ "$status" -eq 0 ]
  [ ! -e "$F" ]
  [ "$(log_lines)" -eq 1 ]
  [[ "$output" == *'設定を消しました'* ]]
  [[ "$output" == *ATST_HEARTBEAT_URL* ]]
  no_url_shown
  run bash "$S" <<< ""
  [ "$status" -eq 0 ]
  [ ! -e "$F" ]
  put_file "$U"
  run bash "$S" <<< "   "
  [ "$status" -eq 0 ]
  [ ! -e "$F" ]
  [ "$(log_lines)" -eq 1 ]
}

@test "SH-8: an invalid value saves nothing, sends nothing and exits 1 (AC16)" {
  local v c0
  put_file "$UF"
  c0=$(cksum < "$F")
  for v in 'ftp://x' 'https://a b' 'https://x"y' 'https://x\y' 'https:///' 'https://' 'example.invalid/ping'; do
    echo "case=$v"
    run bash "$S" <<< "$v"
    [ "$status" -eq 1 ]
    [ "$(cksum < "$F")" = "$c0" ]
    [ "$(log_lines)" -eq 0 ]
    [[ "$output" == *'URL の形式が正しくありません'* ]]
    no_url_shown
  done
  rm -f "$F"
  run bash "$S" <<< 'ftp://x'
  [ "$status" -eq 1 ]
  [ ! -e "$F" ]
}

@test "SH-9: trailing slashes are removed before saving" {
  local v
  for v in "$U/" "$U///"; do
    echo "case=$v"
    rm -f "$LOG"
    run bash "$S" <<< "$v"
    [ "$status" -eq 0 ]
    [ "$(cat "$F")" = "$U" ]
    [[ "$(cat "$LOG")" == *" | url = \"$U\"" ]]
  done
}

@test "SH-10: EOF (no input) changes nothing and exits 1" {
  local c0
  put_file "$UF"
  c0=$(cksum < "$F")
  run bash "$S" < /dev/null
  [ "$status" -eq 1 ]
  [ "$(cksum < "$F")" = "$c0" ]
  [ "$(log_lines)" -eq 0 ]
  [[ "$output" == *'入力がありませんでした'* ]]
  no_url_shown
}

@test "SH-11: one line without a final newline is still taken as input" {
  run bash -c 'printf %s "$1" | bash "$2"' _ "$U" "$S"
  [ "$status" -eq 0 ]
  [ "$(cat "$F")" = "$U" ]
  [[ "$output" != *'入力がありませんでした'* ]]
}

@test "SH-12: a file that cannot be written fails without a test ping" {
  mkdir "$F"
  run bash "$S" <<< "$U"
  [ "$status" -eq 1 ]
  [[ "$output" == *'保存できませんでした'* ]]
  [ "$(log_lines)" -eq 0 ]
  no_url_shown
}

@test "SH-13: no output shows the URL or a part of it; the masked tail is shown (AC17, AC21)" {
  run bash "$S" <<< "$U"
  no_url_shown
  [[ "$output" == *'****9876'* ]]
  export ATST_TEST_CURL_HTTP_CODE=404
  run bash "$S" <<< "$U/"
  no_url_shown
  unset ATST_TEST_CURL_HTTP_CODE
  run bash "$S" <<< ""
  no_url_shown
  run bash "$S" <<< 'https://example.invalid/a b'
  no_url_shown
  run bash "$S" < /dev/null
  no_url_shown
}

@test "SH-14: the config is not changed, nothing goes to LINE, one curl call only" {
  local c0
  atst_test_set_config ATST_HEARTBEAT_URL https://example.invalid/config/xxxx1111
  c0=$(cksum < "$HOME/.atst/config")
  run bash "$S" <<< "$U"
  [ "$status" -eq 0 ]
  [ "$(cksum < "$HOME/.atst/config")" = "$c0" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(log_lines)" -eq 1 ]
}

@test "ST-4: setup_heartbeat.sh is executable (AC3)" {
  [ -x "$S" ]
}
