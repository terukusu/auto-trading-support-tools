#!/usr/bin/env bats
# send_to_line.sh / atst_send_to_line: runs against the curl stub; text cut, return codes, error log,
# images and the payload without jq (PR #71, #83, #87). Images go to ImgBB only, and only with an API
# key (atst_has_imgbb_key / atst_upload_image, #135). The key used here is a dummy string.

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

# ImgBB response with data.url (and the other *url keys that must not be picked).
IMGBB_OK='{"data":{"id":"x","url_viewer":"https:\/\/ibb.co\/x","url":"https:\/\/i.ibb.co\/x\/a.png","display_url":"https:\/\/i.ibb.co\/x\/b.png"},"success":true,"status":200}'

# Number of ImgBB uploads recorded by the curl stub (0 when there is no log).
imgbb_count() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep -c 'api.imgbb.com/1/upload' "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

# Number of lines in the curl log (0 when there is no log).
curl_lines() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    wc -l < "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

# Writes the dummy key to the sandbox ~/.atst/.imgbb_key (before or after common.sh is read).
set_imgbb_key() {
  mkdir -p "$HOME/.atst"
  printf 'secretkey123\n' > "$HOME/.atst/.imgbb_key"
  chmod 600 "$HOME/.atst/.imgbb_key"
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

@test "SR-2: L4: two images add two image messages" {
  set_imgbb_key
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  : > "$ATST_TEST_SANDBOX/i1.png"
  : > "$ATST_TEST_SANDBOX/i2.png"
  run bash -c 'echo hello | bash "$1" "$2" "$3"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh" \
    "$ATST_TEST_SANDBOX/i1.png" "$ATST_TEST_SANDBOX/i2.png"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  [ "$(last_payload | grep -o '"type":"image"' | wc -l)" -eq 2 ]
  [ "$(imgbb_count)" -eq 2 ]
  last_payload | grep -qF 'https://i.ibb.co/x/a.png'
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep -c secretkey123 "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "SR-3: L4: five images are capped at four" {
  local n imgs=()
  set_imgbb_key
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  for n in 1 2 3 4 5; do
    : > "$ATST_TEST_SANDBOX/i$n.png"
    imgs+=("$ATST_TEST_SANDBOX/i$n.png")
  done
  run bash -c 'echo hello | bash "$@"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh" "${imgs[@]}"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  [ "$(last_payload | grep -o '"type":"image"' | wc -l)" -eq 4 ]
  [ "$(imgbb_count)" -eq 4 ]
}

@test "L4: a missing image is noted in the text and the push is still sent" {
  run bash -c 'echo hello | bash "$1" "$2"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh" "$ATST_TEST_SANDBOX/missing.png"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  [[ "$(last_payload | jq -r '.messages[0].text')" == *'画像アップロード失敗: 1枚'* ]]
}

@test "SR-5: L4: without an ImgBB key an image is not uploaded and the text notes it" {
  : > "$ATST_TEST_SANDBOX/i1.png"
  run bash -c 'echo hello | bash "$1" "$2"' _ "$BATS_TEST_DIRNAME/../send_to_line.sh" "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq 1 ]
  [ "$(last_payload | grep -o '"type":"image"' | wc -l)" -eq 0 ]
  [ "$(imgbb_count)" -eq 0 ]
  [ "$(curl_lines)" -eq 1 ]
  [[ "$(last_payload | jq -r '.messages[0].text')" == *'(画像アップロード失敗: 1枚)'* ]]
  [ ! -e "$HOME/.atst/line_error.log" ]
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

@test "UK-1: atst_has_imgbb_key returns 0 with a key, prints nothing and changes nothing" {
  local before after
  atst_test_source_common || return 1
  set_imgbb_key
  before=$(ls -A "$ATST_CONFIG_DIR")
  run atst_has_imgbb_key
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  after=$(ls -A "$ATST_CONFIG_DIR")
  [ "$before" = "$after" ]
  [ ! -e "$ATST_TEST_CURL_LOG" ]
}

@test "UK-2: atst_has_imgbb_key returns 1 without the key file" {
  atst_test_source_common || return 1
  run atst_has_imgbb_key
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "UK-3: atst_has_imgbb_key returns 1 for an empty key file" {
  atst_test_source_common || return 1
  : > "$ATST_CONFIG_DIR/.imgbb_key"
  run atst_has_imgbb_key
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "UK-4: atst_has_imgbb_key returns 1 for a key file with CR/LF only" {
  atst_test_source_common || return 1
  printf '\r\n\n' > "$ATST_CONFIG_DIR/.imgbb_key"
  run atst_has_imgbb_key
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "UK-5: atst_has_imgbb_key returns 1 when ATST_CONFIG_DIR is empty" {
  atst_test_source_common || return 1
  set_imgbb_key
  ATST_CONFIG_DIR= run atst_has_imgbb_key
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "UK-6: atst_has_imgbb_key returns 1 without a message for an unreadable key file" {
  [ "$EUID" -eq 0 ] && skip "root can read mode 000"
  atst_test_source_common || return 1
  set_imgbb_key
  chmod 000 "$ATST_CONFIG_DIR/.imgbb_key"
  run atst_has_imgbb_key
  chmod 600 "$ATST_CONFIG_DIR/.imgbb_key"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "UP-1: with a key ImgBB gets one POST (expiration=86400) and its data.url is returned" {
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  set_imgbb_key
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 0 ]
  [ "$output" = "https://i.ibb.co/x/a.png" ]
  [ "$(curl_lines)" -eq 1 ]
  grep -qF 'https://api.imgbb.com/1/upload' "$ATST_TEST_CURL_LOG"
  grep -qF 'expiration=86400' "$ATST_TEST_CURL_LOG"
  grep -qF "image=@$ATST_TEST_SANDBOX/i1.png" "$ATST_TEST_CURL_LOG"
  grep -qF 'key=</dev/fd/' "$ATST_TEST_CURL_LOG"
  grep -qF -- '-4' "$ATST_TEST_CURL_LOG"
  grep -qF -- '--max-time 60' "$ATST_TEST_CURL_LOG"
  grep -qF -- '--connect-timeout 10' "$ATST_TEST_CURL_LOG"
  # the key is passed through a pipe, not on the command line
  [ "$(grep -c secretkey123 "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c secretkey123)" -eq 0 ]
  [ ! -e "$HOME/.atst/line_error.log" ]
}

@test "UP-1b: the templates/config default sends expiration=86400" {
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_set_config ATST_DAILY_REPORT 1
  atst_test_source_common || return 1
  set_imgbb_key
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 0 ]
  [ "$(curl_lines)" -eq 1 ]
  grep -qF 'expiration=86400' "$ATST_TEST_CURL_LOG"
}

@test "UP-2: without a key no curl is run, nothing is logged and one line goes to stderr" {
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 1 ]
  [ ! -e "$ATST_TEST_CURL_LOG" ] || [ ! -s "$ATST_TEST_CURL_LOG" ]
  [ ! -e "$ATST_CONFIG_DIR/line_error.log" ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *setup_imgbb.sh* ]]
}

@test "UP-3: a key file with CR/LF only is the same as no key" {
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  printf '\r\n\n' > "$ATST_CONFIG_DIR/.imgbb_key"
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 1 ]
  [ ! -e "$ATST_TEST_CURL_LOG" ] || [ ! -s "$ATST_TEST_CURL_LOG" ]
  [ ! -e "$ATST_CONFIG_DIR/line_error.log" ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *setup_imgbb.sh* ]]
}

@test "UP-4: ImgBB 500 returns 1, one curl line and http=upload:imgbb=500" {
  export ATST_TEST_CURL_HTTP_CODE=500
  export ATST_TEST_CURL_BODY='<html>error</html>'
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  set_imgbb_key
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 1 ]
  [ "$(curl_lines)" -eq 1 ]
  grep -qF 'api.imgbb.com/1/upload' "$ATST_TEST_CURL_LOG"
  grep -q 'http=upload:imgbb=500 script=' "$HOME/.atst/line_error.log"
  grep -q '画像アップロード失敗: i1.png' "$HOME/.atst/line_error.log"
  # ImgBB only: no other uploader and no trailing comma in the http field
  [ "$(grep 'http=upload:' "$HOME/.atst/line_error.log" | grep -vc 'http=upload:imgbb=500 script=')" -eq 0 ]
  [[ "$output" == *'Error: Upload failed'* ]]
  [ "$(grep -c secretkey123 "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep -c secretkey123 "$HOME/.atst/line_error.log")" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c secretkey123)" -eq 0 ]
}

@test "UP-5: an ImgBB 200 without a URL in the body is a failure" {
  export ATST_TEST_CURL_BODY='{"success":false,"error":{"code":100}}'
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  set_imgbb_key
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 1 ]
  [ "$(curl_lines)" -eq 1 ]
  grep -q 'http=upload:imgbb=200 script=' "$HOME/.atst/line_error.log"
}

@test "UP-6: a curl failure (000) is logged as http=upload:imgbb=000" {
  export ATST_TEST_CURL_HTTP_CODE=000
  export ATST_TEST_CURL_EXIT=28
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  set_imgbb_key
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 1 ]
  [ "$(curl_lines)" -eq 1 ]
  grep -q 'http=upload:imgbb=000 script=' "$HOME/.atst/line_error.log"
}

@test "UP-7: an old config without ATST_IMGBB_EXPIRATION uses the common.sh default 86400" {
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_IMGBB_EXPIRATION=/d' "$HOME/.atst/config"
  unset ATST_IMGBB_EXPIRATION
  atst_test_source_common || return 1
  set_imgbb_key
  run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 0 ]
  grep -qF 'expiration=86400' "$ATST_TEST_CURL_LOG"
  [ "$(grep -o 'expiration=[0-9]*' "$ATST_TEST_CURL_LOG" | grep -vc '^expiration=86400$')" -eq 0 ]
}

@test "UP-8: ATST_IMGBB_EXPIRATION is passed to ImgBB" {
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  : > "$ATST_TEST_SANDBOX/i1.png"
  atst_test_source_common || return 1
  set_imgbb_key
  ATST_IMGBB_EXPIRATION=3600 run atst_upload_image "$ATST_TEST_SANDBOX/i1.png"
  [ "$status" -eq 0 ]
  grep -qF 'expiration=3600' "$ATST_TEST_CURL_LOG"
}

@test "UP-9: a missing file returns 1 without curl even with a key" {
  atst_test_source_common || return 1
  set_imgbb_key
  run atst_upload_image "$ATST_TEST_SANDBOX/missing.png"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: File not found: $ATST_TEST_SANDBOX/missing.png"* ]]
  [ ! -e "$ATST_TEST_CURL_LOG" ] || [ ! -s "$ATST_TEST_CURL_LOG" ]
  [ ! -e "$ATST_CONFIG_DIR/line_error.log" ]
}
