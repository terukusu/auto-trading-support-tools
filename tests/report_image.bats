#!/usr/bin/env bats
# report_image.sh (#135): the text summary is always sent; the graphs only with an ImgBB key, the
# desktop image only with a key and ATST_IMAGE_REPORT_DESKTOP=1. gnuplot / vncsnapshot are stubs made
# in the sandbox (the real ones and the VNC desktop are never touched); LINE / ImgBB go to the curl stub.
# The key and the LINE token used here are dummy strings.

load test_helper

setup() {
  atst_test_setup_sandbox
  # a value in the developer's environment must not leak in (the config is the input)
  unset ATST_IMAGE_REPORT_DESKTOP ATST_IMGBB_EXPIRATION
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
}

teardown() {
  atst_test_teardown_sandbox
}

IMGBB_OK='{"data":{"id":"x","url_viewer":"https:\/\/ibb.co\/x","url":"https:\/\/i.ibb.co\/x\/a.png","display_url":"https:\/\/i.ibb.co\/x\/b.png"},"success":true,"status":200}'

# gnuplot: reads stdin, records the call, prints a fake image. vncsnapshot: records the call with its
# arguments and writes a fake image to its last argument.
make_image_stubs() {
  cat > "$ATST_TEST_SANDBOX/bin/gnuplot" <<EOF
#!/bin/bash
cat > /dev/null
echo "gnuplot \$(date +%s)" >> "$ATST_TEST_SANDBOX/calls.log"
printf PNG
EOF
  cat > "$ATST_TEST_SANDBOX/bin/vncsnapshot" <<EOF
#!/bin/bash
{ printf vncsnapshot; for a in "\$@"; do printf ' [%s]' "\$a"; done; echo; } >> "$ATST_TEST_SANDBOX/calls.log"
for last in "\$@"; do :; done
printf JPG > "\$last"
EOF
  chmod 755 "$ATST_TEST_SANDBOX/bin/gnuplot" "$ATST_TEST_SANDBOX/bin/vncsnapshot"
}

# Every command on PATH except the given names, linked into $ATST_TEST_SANDBOX/minbin.
# Run with PATH="$BATS_TEST_DIRNAME/stubs:$ATST_TEST_SANDBOX/minbin".
make_minbin() {
  local d name args=()
  local minbin="$ATST_TEST_SANDBOX/minbin"
  mkdir -p "$minbin"
  for name in "$@"; do
    args+=(! -name "$name")
  done
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    find "$d" -mindepth 1 -maxdepth 1 "${args[@]}" -exec ln -s -t "$minbin" {} + 2>/dev/null || true
  done
}

set_imgbb_key() {
  mkdir -p "$HOME/.atst"
  printf 'secretkey123\n' > "$HOME/.atst/.imgbb_key"
  chmod 600 "$HOME/.atst/.imgbb_key"
}

# The standard CSV: bid 150.0 / spread 10 500 s ago, bid 151.5 / spread 25 60 s ago, pip 0.01.
make_standard_mt() {
  local name="${1:-A_MT4}"
  atst_test_make_mt "$name" MT4
  atst_test_make_monitoring_csv "$name" 500 150.0 10 0.01
  atst_test_make_monitoring_csv "$name" 60 151.5 25 0.01
}

imgbb_count() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep -c 'api.imgbb.com/1/upload' "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

# stub_calls <name>: the number of calls of a sandbox stub recorded in calls.log.
stub_calls() {
  if [ -e "$ATST_TEST_SANDBOX/calls.log" ]; then
    grep -c "^$1 " "$ATST_TEST_SANDBOX/calls.log"
  else
    echo 0
  fi
}

# nth_payload <n>: the JSON payload of the n-th push.
nth_payload() {
  local line
  line=$(grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | sed -n "${1}p")
  printf '%s\n' "${line#* -d }"
}

last_payload() {
  local line
  line=$(grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | tail -1)
  printf '%s\n' "${line#* -d }"
}

image_count() {
  printf '%s\n' "$1" | grep -o '"type":"image"' | wc -l
}

run_report() {
  run bash "$BATS_TEST_DIRNAME/../report_image.sh" "$@"
}

@test "RI-1: without a key: exit 0, one push with the text summary only, no ImgBB / gnuplot / vncsnapshot" {
  local p
  [ "$(command -v curl)" = "$BATS_TEST_DIRNAME/stubs/curl" ]
  make_image_stubs
  make_standard_mt
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  p=$(last_payload)
  [ "$(image_count "$p")" -eq 0 ]
  [[ "$p" == *'定期レポート(過去24時間)'* ]]
  [[ "$p" == *'■A_MT4 (USDJPY)'* ]]
  [[ "$p" == *'スプレッド: 最小 10 / 最大 25'* ]]
  [[ "$p" == *'値動き: 安値 150.0 / 高値 151.5 (値幅 150.0 pips)'* ]]
  [[ "$p" == *'最終データ: '* ]]
  [[ "$p" == *'画像は ImgBB の API キーが未設定のため省略 (setup_imgbb.sh で設定)'* ]]
  [[ "$p" != *'(画像アップロード失敗'* ]]
  [ "$(imgbb_count)" -eq 0 ]
  [ "$(stub_calls gnuplot)" -eq 0 ]
  [ "$(stub_calls vncsnapshot)" -eq 0 ]
}

@test "RI-2: with a key and the template config (DESKTOP=0): two graphs, no desktop" {
  local p
  make_image_stubs
  make_standard_mt
  set_imgbb_key
  atst_test_set_config ATST_DAILY_REPORT 1
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(imgbb_count)" -eq 2 ]
  p=$(last_payload)
  [ "$(image_count "$p")" -eq 2 ]
  [ "$(stub_calls gnuplot)" -eq 2 ]
  [ "$(stub_calls vncsnapshot)" -eq 0 ]
  [[ "$p" == *'■A_MT4 (USDJPY)'* ]]
  [[ "$p" == *'・A_MT4 のスプレッド推移'* ]]
  [[ "$p" == *'・A_MT4 の値動き'* ]]
  [[ "$p" != *'ImgBB の API キーが未設定'* ]]
}

@test "RI-2b: with a key and an old config without ATST_IMAGE_REPORT_DESKTOP: no desktop" {
  make_image_stubs
  make_standard_mt
  set_imgbb_key
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_IMAGE_REPORT_DESKTOP=/d' "$HOME/.atst/config"
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(stub_calls vncsnapshot)" -eq 0 ]
  [ "$(imgbb_count)" -eq 2 ]
}

@test "RI-3: with a key and ATST_IMAGE_REPORT_DESKTOP=1: desktop + graphs, no secret leaks, no temp dir left" {
  local p
  make_image_stubs
  make_standard_mt
  set_imgbb_key
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 1
  atst_test_set_config ATST_LINE_TOKEN dummytok135
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(stub_calls vncsnapshot)" -eq 1 ]
  grep '^vncsnapshot ' "$ATST_TEST_SANDBOX/calls.log" | grep -qF "[-passwd] [$HOME/.vnc/passwd]"
  grep '^vncsnapshot ' "$ATST_TEST_SANDBOX/calls.log" | grep -qF '[:1]'
  [ "$(imgbb_count)" -eq 3 ]
  p=$(last_payload)
  [ "$(image_count "$p")" -eq 3 ]
  [[ "$p" == *'・デスクトップ画像('* ]]
  # RI-9 (key not exposed) / R18
  [ "$(grep -c 'secretkey123\|dummytok135' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  if [ -e "$HOME/.atst/line_error.log" ]; then
    [ "$(grep -c 'secretkey123\|dummytok135' "$HOME/.atst/line_error.log")" -eq 0 ]
  fi
  [ "$(printf '%s\n' "$output" | grep -c 'secretkey123\|dummytok135')" -eq 0 ]
  [ "$(ls -d "$HOME/.atst"/report_image.* 2>/dev/null | wc -l)" -eq 0 ]
}

@test "RI-4: ATST_IMAGE_REPORT_TERM=0 sends nothing and calls no stub" {
  make_image_stubs
  make_standard_mt
  set_imgbb_key
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 1
  atst_test_set_config ATST_IMAGE_REPORT_TERM 0
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ ! -e "$ATST_TEST_CURL_LOG" ]
  [ ! -e "$ATST_TEST_SANDBOX/calls.log" ]
  [ "$(ls -d "$HOME/.atst"/report_image.* 2>/dev/null | wc -l)" -eq 0 ]
}

@test "RI-4b: ATST_IMAGE_REPORT_TERM=0 is checked before gnuplot / vncsnapshot are looked for" {
  make_standard_mt
  set_imgbb_key
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 1
  atst_test_set_config ATST_IMAGE_REPORT_TERM 0
  make_minbin gnuplot vncsnapshot
  PATH="$BATS_TEST_DIRNAME/stubs:$ATST_TEST_SANDBOX/minbin" run bash "$BATS_TEST_DIRNAME/../report_image.sh" A_MT4
  [ "$status" -eq 0 ]
  [[ "$output" != *'not found'* ]]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "RI-5: without vncsnapshot / gnuplot on PATH (no key, DESKTOP default) it exits 0 and sends" {
  make_standard_mt
  make_minbin gnuplot vncsnapshot
  [ -z "$(PATH="$BATS_TEST_DIRNAME/stubs:$ATST_TEST_SANDBOX/minbin"; command -v gnuplot vncsnapshot)" ]
  PATH="$BATS_TEST_DIRNAME/stubs:$ATST_TEST_SANDBOX/minbin" run bash "$BATS_TEST_DIRNAME/../report_image.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(image_count "$(last_payload)")" -eq 0 ]
  [[ "$output" != *'not found'* ]]
}

@test "RI-6: with a key and DESKTOP=1 but no vncsnapshot: one warning, graphs still sent" {
  make_image_stubs
  rm -f "$ATST_TEST_SANDBOX/bin/vncsnapshot"
  make_standard_mt
  set_imgbb_key
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 1
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  make_minbin vncsnapshot
  PATH="$BATS_TEST_DIRNAME/stubs:$ATST_TEST_SANDBOX/minbin" run bash "$BATS_TEST_DIRNAME/../report_image.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(image_count "$(last_payload)")" -eq 2 ]
  [ "$(imgbb_count)" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c vncsnapshot)" -eq 1 ]
  [[ "$(last_payload)" != *'デスクトップ画像'* ]]
}

@test "RI-7: with a key but no gnuplot: one warning, the summary only, no upload failure note" {
  local p
  make_standard_mt
  set_imgbb_key
  make_minbin gnuplot vncsnapshot
  PATH="$BATS_TEST_DIRNAME/stubs:$ATST_TEST_SANDBOX/minbin" run bash "$BATS_TEST_DIRNAME/../report_image.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  p=$(last_payload)
  [ "$(image_count "$p")" -eq 0 ]
  [ "$(imgbb_count)" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'gnuplot not found')" -eq 1 ]
  [[ "$p" == *'■A_MT4 (USDJPY)'* ]]
  [[ "$p" != *'ImgBB の API キーが未設定'* ]]
  [[ "$p" != *'(画像アップロード失敗'* ]]
}

@test "RI-8: five images are split 4 + 1 and the summaries go in the first push only" {
  local p1 p2
  make_image_stubs
  make_standard_mt A_MT4
  make_standard_mt B_MT4
  set_imgbb_key
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 1
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  run_report A_MT4 B_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(imgbb_count)" -eq 5 ]
  p1=$(nth_payload 1)
  p2=$(nth_payload 2)
  [ "$(image_count "$p1")" -eq 4 ]
  [[ "$p1" == *'■A_MT4'* ]]
  [[ "$p1" == *'■B_MT4'* ]]
  [ "$(image_count "$p2")" -eq 1 ]
  [[ "$p2" == *'定期レポート(過去24時間)'* ]]
  [[ "$p2" != *'■'* ]]
}

@test "RI-9: an MT without terminal_monitoring.csv only: nothing is sent" {
  make_image_stubs
  atst_test_make_mt A_MT4 MT4
  set_imgbb_key
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(imgbb_count)" -eq 0 ]
  [ "$(stub_calls vncsnapshot)" -eq 0 ]
}

@test "RI-9b: no CSV but DESKTOP=1 with a key: the desktop image alone is sent" {
  make_image_stubs
  atst_test_make_mt A_MT4 MT4
  set_imgbb_key
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 1
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(image_count "$(last_payload)")" -eq 1 ]
}

@test "RI-10: ATST_IMAGE_REPORT_DESKTOP other than 1 (yes) keeps the desktop off" {
  make_image_stubs
  make_standard_mt
  set_imgbb_key
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP yes
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(stub_calls vncsnapshot)" -eq 0 ]
  [ "$(imgbb_count)" -eq 2 ]
}

@test "RI-11: no line within the term: one 'no data' line and still one push" {
  local p
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 90000 150.0 10 0.01
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  p=$(last_payload)
  [[ "$p" == *'■A_MT4 (USDJPY): 過去24時間のデータがありません'* ]]
  [[ "$p" != *'スプレッド:'* ]]
}

@test "RI-12: a failed push exits 1 and is logged" {
  make_standard_mt
  export ATST_TEST_CURL_HTTP_CODE=500
  run_report A_MT4
  [ "$status" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -q 'http=500' "$HOME/.atst/line_error.log"
  grep -q 'script=report_image.sh' "$HOME/.atst/line_error.log"
}

@test "RI-12b: the first of two pushes failing still sends the second and exits 1" {
  make_image_stubs
  make_standard_mt A_MT4
  make_standard_mt B_MT4
  set_imgbb_key
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 1
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  # curl calls: ImgBB x4, push (500), ImgBB, push
  export ATST_TEST_CURL_HTTP_CODE_SEQ="200 200 200 200 500"
  run_report A_MT4 B_MT4
  [ "$status" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 2 ]
}

@test "RI-13: no argument prints the usage and exits 1" {
  run_report
  [ "$status" -eq 1 ]
  [[ "$output" == *'Usage:'* ]]
  [ ! -e "$ATST_TEST_CURL_LOG" ]
}

@test "RI-14: a pip that is not a positive number gives '-' for the range" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 60 150.0 10 0
  run_report A_MT4
  [ "$status" -eq 0 ]
  [[ "$(last_payload)" == *'(値幅 - pips)'* ]]
}

@test "RI-15: values are compared as numbers and printed as written in the CSV" {
  local p
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 500 99.5 9 0.01
  atst_test_make_monitoring_csv A_MT4 60 100.25 10 0.01
  run_report A_MT4
  [ "$status" -eq 0 ]
  p=$(last_payload)
  [[ "$p" == *'スプレッド: 最小 9 / 最大 10'* ]]
  [[ "$p" == *'値動き: 安値 99.5 / 高値 100.25 (値幅 75.0 pips)'* ]]
}

@test "RI-16: CRLF lines give no CR in the summary" {
  local p
  atst_test_make_mt A_MT4 MT4
  mkdir -p "$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files"
  printf '%s,0,150.0,150.0,10,12,0.01,USDJPY\r\n' "$(( $(date +%s) - 60 ))" \
    > "$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
  run_report A_MT4
  [ "$status" -eq 0 ]
  p=$(last_payload)
  [[ "$p" == *'■A_MT4 (USDJPY)'* ]]
  [[ "$p" == *'最大 10'* ]]
  [ "$(printf '%s\n' "$p" | grep -c '\\r')" -eq 0 ]
}

@test "RI-17: the last data time is printed as MM/DD HH:MM" {
  local last want
  make_standard_mt
  last=$(tail -n 1 "$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv" | cut -d, -f1)
  want=$(date -d "@$last" '+%m/%d %H:%M')
  run_report A_MT4
  [ "$status" -eq 0 ]
  [[ "$(last_payload)" == *"最終データ: $want"* ]]
}

@test "RI-18: nothing goes to stdout (no image URL, no key)" {
  make_image_stubs
  make_standard_mt
  set_imgbb_key
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
  run bash -c 'bash "$1" A_MT4 2>/dev/null' _ "$BATS_TEST_DIRNAME/../report_image.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "RI-19: with a key, ImgBB failing for the graphs notes it in the text and exits 0" {
  make_image_stubs
  make_standard_mt
  set_imgbb_key
  export ATST_TEST_CURL_BODY='{"success":false,"error":{"code":100}}'
  run_report A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(image_count "$(last_payload)")" -eq 0 ]
  [[ "$(last_payload)" == *'(画像アップロード失敗: 2枚)'* ]]
  [ "$(grep -c 'http=upload:imgbb=200' "$HOME/.atst/line_error.log")" -eq 2 ]
}
