#!/usr/bin/env bats
# send_to_line.sh / atst_send_to_line: runs against the curl stub; text cut, return codes, error log,
# images and the payload without jq (PR #71, #83, #87).

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

# Prints the JSON payload of the last push recorded by the curl stub.
last_payload() {
  local line
  line=$(grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | tail -1)
  printf '%s\n' "${line#* -d }"
}

push_count() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep -c 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

@test "L1: a 6000-character message is cut to 4900 characters ending with …(以下省略)" {
  local text len
  run bash -c 'printf "あ%.0s" $(seq 1 6000) | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
  [ "$status" -eq 0 ]
  text=$(last_payload | jq -r '.messages[0].text')
  len=$(LC_ALL=C.UTF-8; printf '%s' "${#text}")
  [ "$len" -le 4900 ]
  [ "$len" -gt 4800 ]
  [[ "$text" == *'…(以下省略)' ]]
}

@test "L2: return codes are 0 for 200, 2 for 400 and 1 for 401/403/429/500/curl failure" {
  local code want bad=""
  for code in 200:0 400:2 401:1 403:1 429:1 500:1; do
    want=${code#*:}
    ATST_TEST_CURL_HTTP_CODE=${code%:*} run bash -c 'echo hello | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
    [ "$status" -eq "$want" ] || bad+=" ${code%:*}->$status"
  done
  ATST_TEST_CURL_HTTP_CODE=000 ATST_TEST_CURL_EXIT=28 run bash -c 'echo hello | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
  [ "$status" -eq 1 ] || bad+=" 000->$status"
  [ -z "$bad" ]
}

@test "L3: line_error.log records http, script and the message head on failure only" {
  run bash -c 'echo hello-l3 | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.atst/line_error.log" ]
  ATST_TEST_CURL_HTTP_CODE=500 run bash -c 'echo hello-l3 | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
  [ "$status" -eq 1 ]
  grep -q 'http=500' "$HOME/.atst/line_error.log"
  grep -q 'script=send_to_line.sh' "$HOME/.atst/line_error.log"
  grep -q 'message: .*hello-l3' "$HOME/.atst/line_error.log"
}

@test "L4: two images add two image messages" {
  export ATST_TEST_CURL_BODY=https://example.com/a.png
  : > "$ATST_TEST_SANDBOX/i1.png"
  : > "$ATST_TEST_SANDBOX/i2.png"
  run bash -c 'echo hello | bash "$1" "$2" "$3"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh" \
    "$ATST_TEST_SANDBOX/i1.png" "$ATST_TEST_SANDBOX/i2.png"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  [ "$(last_payload | grep -o '"type":"image"' | wc -l)" -eq 2 ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "L4: five images are capped at four" {
  local n imgs=()
  export ATST_TEST_CURL_BODY=https://example.com/a.png
  for n in 1 2 3 4 5; do
    : > "$ATST_TEST_SANDBOX/i$n.png"
    imgs+=("$ATST_TEST_SANDBOX/i$n.png")
  done
  run bash -c 'echo hello | bash "$@"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh" "${imgs[@]}"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  [ "$(last_payload | grep -o '"type":"image"' | wc -l)" -eq 4 ]
}

@test "L4: a missing image is noted in the text and the push is still sent" {
  run bash -c 'echo hello | bash "$1" "$2"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh" "$ATST_TEST_SANDBOX/missing.png"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  [[ "$(last_payload | jq -r '.messages[0].text')" == *'画像アップロード失敗: 1枚'* ]]
}

@test "L5: without jq the payload is still valid JSON with the same text" {
  local JQ nojq d with_jq without_jq
  JQ=$(command -v jq)
  [ -n "$JQ" ]
  run bash -c 'printf "a\"b/c\nx\n" | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
  [ "$status" -eq 0 ]
  with_jq=$(last_payload | "$JQ" -r '.messages[0].text')
  [[ "$with_jq" == *'a"b/c'* ]]

  # Every command on PATH except jq, so common.sh takes its jq-less branch.
  nojq="$ATST_TEST_SANDBOX/nojq"
  mkdir -p "$nojq"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    find "$d" -mindepth 1 -maxdepth 1 ! -name jq -exec ln -s -t "$nojq" {} + 2>/dev/null || true
  done
  unset IFS
  [ -z "$(PATH="$BATS_TEST_DIRNAME/stubs:$nojq"; command -v jq)" ]

  PATH="$BATS_TEST_DIRNAME/stubs:$nojq" run bash -c 'printf "a\"b/c\nx\n" | bash "$1"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 2 ]
  last_payload | "$JQ" -e . >/dev/null
  # atst_escape_text escapes "/" (jq does not): the jq-less branch was taken.
  last_payload | grep -qF 'b\/c'
  without_jq=$(last_payload | "$JQ" -r '.messages[0].text')
  [ "$without_jq" = "$with_jq" ]
}

@test "U1: Litterbox 200 returns its URL without trying Uguu" {
  export ATST_TEST_CURL_BODY=https://litter.catbox.moe/abc123.png
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 0 ]
  [ "$output" = "https://litter.catbox.moe/abc123.png" ]
  [ "$(wc -l < "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(grep -c 'uguu.se' "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "U2: Litterbox 500 falls back to Uguu and returns the unescaped URL from its JSON" {
  export ATST_TEST_CURL_HTTP_CODE_SEQ="500 200"
  export ATST_TEST_CURL_BODY='{"success": true, "files": [{"hash": "x", "filename": "tfZf.png", "url": "https:\/\/d.uguu.se\/tfZf.png", "size": 10}]}'
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 0 ]
  [ "$output" = "https://d.uguu.se/tfZf.png" ]
  [ "$(grep -c 'litterbox.catbox.moe' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(grep -c 'uguu.se/upload' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ ! -e "$HOME/.atst/line_error.log" ]
}

@test "U3: both uploaders failing returns 1 and logs both HTTP codes" {
  export ATST_TEST_CURL_HTTP_CODE_SEQ="500 503"
  export ATST_TEST_CURL_BODY='<html>error</html>'
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 1 ]
  grep -q 'http=upload:litterbox=500,uguu=503' "$HOME/.atst/line_error.log"
  grep -q '画像アップロード失敗: i1.png' "$HOME/.atst/line_error.log"
}

@test "U4: a Uguu 200 without a URL in the body is a failure" {
  export ATST_TEST_CURL_HTTP_CODE_SEQ="500 200"
  export ATST_TEST_CURL_BODY='{"success": false, "errorcode": 400}'
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 1 ]
  grep -q 'http=upload:litterbox=500,uguu=200' "$HOME/.atst/line_error.log"
}
