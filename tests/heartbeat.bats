#!/usr/bin/env bats
# heartbeat.sh (#136): ping while the monitoring is healthy, <URL>/fail while it reports a problem
# (allow-listed keys of alert_status set to 1, LINE send failures in a row in line_error.log). Also
# the common.sh parts it uses (atst_load_heartbeat_url, atst_line_send_failing) and the "-K" support of
# the curl stub. Every URL is a dummy under example.invalid; nothing leaves the sandbox.

load test_helper

U=https://example.invalid/ping/abcd9876
UC=https://example.invalid/config/xxxx1111
UF=https://example.invalid/file/yyyy2222

setup() {
  atst_test_setup_sandbox
  # the developer's environment must not leak in
  unset ATST_TEST_CURL_BODY ATST_TEST_CURL_HTTP_CODE ATST_TEST_CURL_HTTP_CODE_SEQ ATST_TEST_CURL_EXIT \
    ATST_TEST_CURL_FILE ATST_HEARTBEAT_LINE_FAIL_COUNT ATST_HEARTBEAT_URL ATST_HEARTBEAT_URL_FROM
  LOG=$ATST_TEST_CURL_LOG
  ST=$HOME/.atst/alert_status
  EL=$HOME/.atst/line_error.log
  HF=$HOME/.atst/.heartbeat_url
  mkdir -p "$HOME/.atst"
}

teardown() {
  # HU-7 / HB-21 take permissions away; give them back so the sandbox can be removed.
  chmod -R u+rwX "$ATST_TEST_SANDBOX" 2>/dev/null
  atst_test_teardown_sandbox
}

# Number of lines in the curl log (0 without it).
log_lines() {
  if [ -e "$LOG" ]; then
    wc -l < "$LOG"
  else
    echo 0
  fi
}

# Number of /fail lines (url line ending in /fail") of <pattern> (default abcd9876).
fail_lines() {
  if [ -e "$LOG" ]; then
    grep -c "${1:-abcd9876}/fail\"" "$LOG"
  else
    echo 0
  fi
}

# Number of lines with <pattern> (default abcd9876) and without /fail.
ping_lines() {
  if [ -e "$LOG" ]; then
    grep "${1:-abcd9876}" "$LOG" | grep -vc '/fail'
  else
    echo 0
  fi
}

# The body of the /fail line (data or data-raw), empty without it.
fail_body() {
  if [ -e "$LOG" ]; then
    sed -nE 's/.*data(-raw)? = "([^"]*)".*/\2/p' "$LOG"
  fi
}

# Each log line up to the first " | " (the argv part).
argv_part() {
  if [ -e "$LOG" ]; then
    sed 's/ | .*//' "$LOG"
  fi
}

# set_status <key> <value> [<epoch>]
set_status() {
  printf '%s,%s,%s\n' "$1" "$2" "${3:-$(date +%s)}" >> "$ST"
}

# line_fail <minutes ago> [<http>]: one heading in the form written by atst_log_line_error.
line_fail() {
  printf '[%s] LINE send failed: http=%s script=x.sh\n  response: r\n  message: m\n' \
    "$(date -d "-$1 min" '+%Y-%m-%d %H:%M:%S')" "${2:-500}" >> "$EL"
}

# line_fails <count> <minutes ago> [<http>]
line_fails() {
  local i
  for i in $(seq 1 "$1"); do
    line_fail "$2" "${3:-500}"
  done
}

hb_run() {
  run bash "$BATS_TEST_DIRNAME/../heartbeat.sh" "$@"
}

# The URL source and value seen by a script after common.sh.
hu_run() {
  run bash -c '. "$1/../common.sh"; printf "%s|%s" "$ATST_HEARTBEAT_URL_FROM" "$ATST_HEARTBEAT_URL"' _ "$BATS_TEST_DIRNAME"
}

# A fresh config (the template) with <url> as ATST_HEARTBEAT_URL.
config_url() {
  rm -f "$HOME/.atst/config"
  atst_test_set_config ATST_HEARTBEAT_URL "$1"
}

file_url() {
  printf '%s\n' "$1" > "$HF"
  chmod 600 "$HF"
}

# ---- CS: the curl stub reading -K ----

@test "CS-1: -K url / data-raw lines are recorded trimmed on the same line" {
  local f="$ATST_TEST_SANDBOX/k.cfg"
  printf '  url = "%s/fail"  \ndata-raw = "PROCESS_A"\n' "$U" > "$f"
  run curl -fs -o /dev/null -K "$f"
  [ "$status" -eq 0 ]
  [ "$(log_lines)" -eq 1 ]
  [ "$(cat "$LOG")" = "-fs -o /dev/null -K $f | url = \"$U/fail\" | data-raw = \"PROCESS_A\"" ]
}

@test "CS-2: a data line is recorded too" {
  local f="$ATST_TEST_SANDBOX/k.cfg"
  printf 'url = "%s"\ndata = "X_Y"\n' "$U" > "$f"
  run curl -K "$f"
  [ "$status" -eq 0 ]
  [[ "$(cat "$LOG")" == *' | data = "X_Y"' ]]
}

@test "CS-3: header / user / oauth2-bearer lines of -K are never recorded" {
  local f="$ATST_TEST_SANDBOX/k.cfg"
  printf 'header = "Authorization: Bearer dummytok136"\nuser = "u:pw136"\noauth2-bearer = "ob136"\nurl = "%s"\n' "$U" > "$f"
  run curl -K "$f"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Authorization\|dummytok136\|pw136\|ob136' "$LOG")" -eq 0 ]
  [ "$(grep -c "url = \"$U\"" "$LOG")" -eq 1 ]
}

@test "CS-4: a -H @<file> header file is still neither opened nor recorded" {
  local h="$ATST_TEST_SANDBOX/h"
  printf 'Authorization: Bearer dummytok136\n' > "$h"
  run curl -s -H @"$h" https://api.line.me/x
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "-s -H @$h https://api.line.me/x" ]
  [ "$(grep -c dummytok136 "$LOG")" -eq 0 ]
}

@test "CS-5: an unreadable -K file leaves only the arguments and the stub does not fail" {
  run curl -K "$ATST_TEST_SANDBOX/nosuch"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "-K $ATST_TEST_SANDBOX/nosuch" ]
}

@test "CS-6: a -K file without url / data lines leaves only the arguments" {
  local f="$ATST_TEST_SANDBOX/k.cfg"
  printf 'max-time = 10\nsilent\n' > "$f"
  run curl -K "$f"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "-K $f" ]
}

@test "CS-7: one call is one line, so ATST_TEST_CURL_HTTP_CODE_SEQ still lines up" {
  local f="$ATST_TEST_SANDBOX/k.cfg"
  printf 'url = "%s"\ndata-raw = "A"\n' "$U" > "$f"
  export ATST_TEST_CURL_HTTP_CODE_SEQ="200 404"
  run curl -s -w '%{http_code}' -K "$f"
  [ "${lines[${#lines[@]}-1]}" = 200 ]
  run curl -s -w '%{http_code}' -K "$f"
  [ "$(log_lines)" -eq 2 ]
  [ "${lines[${#lines[@]}-1]}" = 404 ]
  run curl -s -K <(printf 'url = "%s"\ndata-raw = "%s"\n' "$U" A)
  [ "$(log_lines)" -eq 3 ]
  [[ "$(tail -n 1 "$LOG")" == *" | url = \"$U\" | data-raw = \"A\"" ]]
}

@test "CS-8: a call without -K is recorded exactly as before" {
  run curl -s -X POST https://api.line.me/v2/bot/message/push -d '{"a":1}'
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = '-s -X POST https://api.line.me/v2/bot/message/push -d {"a":1}' ]
}

@test "CS-9: outside a sandbox (no ATST_TEST_CURL_LOG) the stub exits 1 and writes nothing" {
  local f="$ATST_TEST_SANDBOX/k.cfg" before
  printf 'url = "%s"\n' "$U" > "$f"
  before=$(find "$ATST_TEST_SANDBOX" | sort)
  run env -u ATST_TEST_CURL_LOG "$BATS_TEST_DIRNAME/stubs/curl" -K "$f"
  [ "$status" -eq 1 ]
  [ "$(find "$ATST_TEST_SANDBOX" | sort)" = "$before" ]
}

# ---- HU: atst_load_heartbeat_url (common.sh) ----

@test "HU-1: .heartbeat_url alone is used (AC18)" {
  file_url "$UF"
  hu_run
  [ "$status" -eq 0 ]
  [ "$output" = "file|$UF" ]
}

@test "HU-2: .heartbeat_url wins over the config (AC18)" {
  config_url "$UC"
  file_url "$UF"
  hu_run
  [ "$output" = "file|$UF" ]
}

@test "HU-3: without .heartbeat_url the config is used (AC18)" {
  config_url "$UC"
  hu_run
  [ "$output" = "config|$UC" ]
}

@test "HU-4: an empty or blank .heartbeat_url falls back to the config" {
  config_url "$UC"
  : > "$HF"
  hu_run
  [ "$output" = "config|$UC" ]
  printf '  \r\n\n' > "$HF"
  hu_run
  [ "$output" = "config|$UC" ]
}

@test "HU-5: neither: both empty" {
  hu_run
  [ "$output" = "|" ]
}

@test "HU-6: spaces and CR are removed and only the first line is read" {
  printf '  %s \r\n%s\n' "$UF" https://example.invalid/other/zzzz3333 > "$HF"
  hu_run
  [ "$output" = "file|$UF" ]
}

@test "HU-7: an unreadable .heartbeat_url or a directory falls back to the config silently" {
  config_url "$UC"
  if [ "$(id -u)" -ne 0 ]; then
    file_url "$UF"
    chmod 000 "$HF"
    hu_run
    chmod 600 "$HF"
    [ "$output" = "config|$UC" ]
    rm -f "$HF"
  fi
  mkdir "$HF"
  hu_run
  [ "$output" = "config|$UC" ]
}

@test "HU-8: returns 0, gives the same result when called again and is not exported" {
  file_url "$UF"
  run bash -c '. "$1/../common.sh"; atst_load_heartbeat_url; echo "rc=$?"; atst_load_heartbeat_url
    printf "%s|%s\n" "$ATST_HEARTBEAT_URL_FROM" "$ATST_HEARTBEAT_URL"
    bash -c "echo sub=\${ATST_HEARTBEAT_URL_FROM-unset}"' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'rc=0\nfile|%s\nsub=unset' "$UF")" ]
}

# ---- LF: atst_line_send_failing (common.sh) ----

@test "LF-1: 3 recent headings with n=3 is true and prints nothing (AC9)" {
  line_fails 3 1
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "LF-2: 2 recent headings with n=3 is false (AC9)" {
  line_fails 2 1
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
}

@test "LF-3: 3 headings 61 minutes old is false (AC9)" {
  line_fails 3 61
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
}

@test "LF-4: 59 minutes is inside; only the last n headings count" {
  line_fails 3 59
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 0 ]
  rm -f "$EL"
  line_fails 2 120
  line_fails 3 1
  run atst_line_send_failing 3
  [ "$status" -eq 0 ]
}

@test "LF-5: the oldest of the last n decides: 61 minutes then 2 recent is false" {
  line_fail 61
  line_fails 2 1
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
}

@test "LF-6: failed image uploads (http=upload:) do not count" {
  line_fails 3 1 upload:imgbb=400
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
}

@test "LF-7: uploads are left out before taking the last n" {
  line_fail 90
  line_fail 1
  line_fail 1 upload:imgbb=400
  line_fail 1
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
  rm -f "$EL"
  line_fails 3 1
  line_fail 1 upload:imgbb=400
  run atst_line_send_failing 3
  [ "$status" -eq 0 ]
}

@test "LF-8: no_alert_status headings count" {
  line_fails 3 1 no_alert_status
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 0 ]
}

@test "LF-9: response / message lines never count, even when they look like a heading" {
  local i ts
  ts=$(date -d '-1 min' '+%Y-%m-%d %H:%M:%S')
  for i in 1 2; do
    printf '[%s] LINE send failed: http=500 script=x.sh\n  response: [%s] LINE send failed: http=500\n  message: [%s] LINE send failed: http=500\n' \
      "$ts" "$ts" "$ts" >> "$EL"
  done
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
}

@test "LF-10: no log, or an empty ATST_CONFIG_DIR, is false and creates nothing" {
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
  [ ! -e "$EL" ]
  line_fails 3 1
  cd "$ATST_TEST_SANDBOX"
  ATST_CONFIG_DIR=
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
  [ ! -e "$ATST_TEST_SANDBOX/line_error.log" ]
}

@test "LF-11: a heading date that cannot be read is false and prints nothing" {
  local i
  for i in 1 2 3; do
    printf '[9999-99-99 99:99:99] LINE send failed: http=500 script=x.sh\n' >> "$EL"
  done
  atst_test_source_common
  run atst_line_send_failing 3
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "LF-12: the log and its directory are not changed" {
  local c0 m0 l0
  line_fails 3 1
  atst_test_source_common
  c0=$(cksum < "$EL"); m0=$(stat -c %Y "$EL"); l0=$(ls -A "$HOME/.atst")
  run atst_line_send_failing 3
  [ "$status" -eq 0 ]
  [ "$(cksum < "$EL")" = "$c0" ]
  [ "$(stat -c %Y "$EL")" = "$m0" ]
  [ "$(ls -A "$HOME/.atst")" = "$l0" ]
}

# ---- HB: heartbeat.sh ----

@test "HB-1: no URL anywhere: no curl call, exit 0, no output, even with problems (AC5, AC12)" {
  set_status PROCESS_A 1
  line_fails 3 1
  hb_run
  [ "$status" -eq 0 ]
  [ "$(log_lines)" -eq 0 ]
  [ -z "$output" ]
}

@test "HB-2: no alert_status: one ping (GET) with the bounded options and nothing printed (AC6, AC12)" {
  local a
  config_url "$U"
  hb_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(log_lines)" -eq 1 ]
  [[ "$(cat "$LOG")" == *" | url = \"$U\"" ]]
  [ "$(grep -c data "$LOG")" -eq 0 ]
  a=" $(argv_part) "
  [[ "$a" == *" -fs "* ]]
  [[ "$a" == *" --max-time 10 "* ]]
  [[ "$a" == *" --retry 3 "* ]]
  [[ "$a" == *" --retry-connrefused "* ]]
  [[ "$a" == *" --retry-max-time 40 "* ]]
  [[ "$a" == *" -o /dev/null "* ]]
  [[ "$a" == *" -K "* ]]
  [[ "$a" != *-fsS* ]]
  [[ "$a" != *" -S "* ]]
}

@test "HB-3: keys outside the allow list never give /fail (AC6)" {
  local k
  config_url "$U"
  for k in PRICE_A SPREAD_A PING_A IMAGE_REPORT_DEFAULT_CHANGED RUNNER_TIMEOUT_HEARTBEAT XPROCESS_A process_a XTICK_A tick_a OTHER_KEY; do
    set_status "$k" 1
  done
  hb_run
  [ "$status" -eq 0 ]
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
}

@test "HB-4: each allow-listed key set to 1 gives one /fail and no ping (AC7, AC12)" {
  local k
  config_url "$U"
  for k in PROCESS_A TARGET_A MONITORING_A TICK_A RUNNER_STUCK RUNNER_TIMEOUT_CHECK_PING RUNNER_TIMEOUT_CHECK_TICK LINE_X; do
    echo "case=$k"
    rm -f "$ST" "$LOG"
    set_status "$k" 1
    hb_run
    [ "$status" -eq 0 ]
    [ "$(log_lines)" -eq 1 ]
    [ "$(fail_lines)" -eq 1 ]
    [ "$(ping_lines)" -eq 0 ]
    [ "$(fail_body)" = "$k" ]
  done
}

@test "HB-5: only the value 1 counts (0, empty, 10, 1x, ' 1' do not) (AC6)" {
  config_url "$U"
  set_status PROCESS_A 0
  set_status PROCESS_B ''
  set_status PROCESS_C 10
  set_status PROCESS_D 1x
  set_status PROCESS_E ' 1'
  hb_run
  [ "$status" -eq 0 ]
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
}

@test "HB-6: the /fail body lists only allow-listed keys in file order (AC8)" {
  local h
  config_url "$U"
  set_status PROCESS_A 1 1700000123
  set_status PRICE_B 1 1700000123
  set_status MONITORING_C 0 1700000123
  set_status TARGET_B 1 1700000123
  hb_run
  [ "$status" -eq 0 ]
  [ "$(fail_body)" = "PROCESS_A TARGET_B" ]
  [ "$(grep -c 'PRICE_B\|MONITORING_C\|1700000123\|【' "$LOG")" -eq 0 ]
  h=$(hostname -s)
  [ -z "$h" ] || [ "$(grep -cF -- "$h" "$LOG")" -eq 0 ]
}

@test "HB-7: the body has only [A-Za-z0-9_ ] and at most 1000 characters" {
  local line rest k body
  config_url "$U"
  printf '%s\n' 'PROCESS_A-B.c,1,1' 'PROCESS_"x\y,1,1' > "$ST"
  hb_run
  [ "$status" -eq 0 ]
  [ "$(fail_body)" = "PROCESS_A_B_c PROCESS__x_y" ]
  line=$(grep '/fail"' "$LOG")
  rest=${line#*data-raw = \"}
  [ "$(printf '%s' "$rest" | tr -cd '"' | wc -c)" -eq 1 ]

  rm -f "$ST" "$LOG"
  for k in $(seq 1 200); do
    printf 'PROCESS_K%04d,1,1\n' "$k" >> "$ST"
  done
  hb_run
  [ "$status" -eq 0 ]
  body=$(fail_body)
  [ "${#body}" -le 1000 ]
  [ "${#body}" -ge 990 ]
  [[ "$body" == "PROCESS_K0001 "* ]]
}

@test "HB-8: 3 recent LINE failures give /fail with LINE_SEND_FAILED last (AC9)" {
  config_url "$U"
  line_fails 3 1
  hb_run
  [ "$status" -eq 0 ]
  [ "$(fail_lines)" -eq 1 ]
  [ "$(fail_body)" = LINE_SEND_FAILED ]
  rm -f "$LOG"
  set_status PROCESS_A 1
  hb_run
  [ "$(fail_body)" = "PROCESS_A LINE_SEND_FAILED" ]
}

@test "HB-9: 2 recent, 3 old (61 min) or 3 upload failures give a ping (AC9)" {
  config_url "$U"
  line_fails 2 1
  hb_run
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
  rm -f "$EL" "$LOG"
  line_fails 3 61
  hb_run
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
  rm -f "$EL" "$LOG"
  line_fails 3 1 upload:imgbb=400
  hb_run
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
}

@test "HB-10: ATST_HEARTBEAT_LINE_FAIL_COUNT=5: 3 failures ping, 5 failures /fail (AC9)" {
  config_url "$U"
  atst_test_set_config ATST_HEARTBEAT_LINE_FAIL_COUNT 5
  line_fails 3 1
  hb_run
  [ "$(fail_lines)" -eq 0 ]
  rm -f "$LOG"
  line_fails 2 1
  hb_run
  [ "$(fail_lines)" -eq 1 ]
}

@test "HB-11: an invalid ATST_HEARTBEAT_LINE_FAIL_COUNT falls back to 3" {
  local v
  for v in abc 0 05 1000 -1 ''; do
    echo "case=$v"
    config_url "$U"
    atst_test_set_config ATST_HEARTBEAT_LINE_FAIL_COUNT "$v"
    rm -f "$EL" "$LOG"
    line_fails 3 1
    hb_run
    [ "$status" -eq 0 ]
    [ "$(fail_lines)" -eq 1 ]
    rm -f "$EL" "$LOG"
    line_fails 2 1
    hb_run
    [ "$status" -eq 0 ]
    [ "$(fail_lines)" -eq 0 ]
  done
}

@test "HB-12: the bounds 1 and 999 are used as they are" {
  config_url "$U"
  atst_test_set_config ATST_HEARTBEAT_LINE_FAIL_COUNT 1
  line_fails 1 1
  hb_run
  [ "$(fail_lines)" -eq 1 ]
  config_url "$U"
  atst_test_set_config ATST_HEARTBEAT_LINE_FAIL_COUNT 999
  rm -f "$EL" "$LOG"
  line_fails 3 1
  hb_run
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
}

@test "HB-13: LINE_QUOTA,1 gives /fail with LINE_QUOTA, LINE_QUOTA,0 a ping (AC10)" {
  config_url "$U"
  set_status LINE_QUOTA 1
  hb_run
  [ "$(fail_lines)" -eq 1 ]
  [ "$(fail_body)" = LINE_QUOTA ]
  rm -f "$ST" "$LOG"
  set_status LINE_QUOTA 0
  hb_run
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
}

@test "HB-14: .heartbeat_url wins, the config is used without it or when it is blank (AC18)" {
  config_url "$UC"
  file_url "$UF"
  hb_run
  [ "$(grep -c 'file/yyyy2222' "$LOG")" -eq 1 ]
  [ "$(grep -c 'config/xxxx1111' "$LOG")" -eq 0 ]
  rm -f "$HF" "$LOG"
  hb_run
  [ "$(grep -c 'config/xxxx1111' "$LOG")" -eq 1 ]
  rm -f "$LOG"
  printf '  \r\n' > "$HF"
  hb_run
  [ "$(grep -c 'config/xxxx1111' "$LOG")" -eq 1 ]
}

@test "HB-15: trailing slashes are removed before use and before /fail" {
  local u
  for u in "$U/" "$U//"; do
    echo "case=$u"
    config_url "$u"
    rm -f "$ST" "$LOG"
    hb_run
    [[ "$(cat "$LOG")" == *" | url = \"$U\"" ]]
    rm -f "$LOG"
    set_status PROCESS_A 1
    hb_run
    [ "$(grep -c "url = \"$U/fail\"" "$LOG")" -eq 1 ]
    [ "$(grep -c '//fail\|abcd9876//' "$LOG")" -eq 0 ]
  done
}

@test "HB-16: a URL with a space, \" or \\ is refused with one line and nothing is sent" {
  local u
  for u in 'https://example.invalid/a b' 'https://example.invalid/a"b' 'https://example.invalid/a\b'; do
    echo "case=$u"
    config_url "$u"
    hb_run
    [ "$status" -eq 1 ]
    [ "$(log_lines)" -eq 0 ]
    [ "$output" = "heartbeat: ATST_HEARTBEAT_URL is invalid" ]
  done
  config_url ""
  printf '%s\n' 'https://example.invalid/a"b' > "$HF"
  hb_run
  [ "$status" -eq 1 ]
  [ "$(log_lines)" -eq 0 ]
  [ "$output" = "heartbeat: ATST_HEARTBEAT_URL is invalid" ]
}

@test "HB-17: the scheme is not checked (a config URL keeps working)" {
  config_url ftp://example.invalid/ping/abcd9876
  hb_run
  [ "$status" -eq 0 ]
  [ "$(log_lines)" -eq 1 ]
  [ "$(grep -c 'url = "ftp://' "$LOG")" -eq 1 ]
}

@test "HB-18: the URL is never in argv, for the ping and for /fail (AC21)" {
  config_url "$U"
  hb_run
  set_status PROCESS_A 1
  hb_run
  [ "$(log_lines)" -eq 2 ]
  [ "$(argv_part | grep -c 'example.invalid\|abcd9876')" -eq 0 ]
}

@test "HB-19: a failed curl: its exit code and one line without the URL (AC21)" {
  config_url "$U"
  export ATST_TEST_CURL_EXIT=6
  hb_run
  [ "$status" -eq 6 ]
  [ "$output" = "heartbeat: send failed (curl exit 6)" ]
  [ "$(log_lines)" -eq 1 ]
  rm -f "$LOG"
  set_status PROCESS_A 1
  hb_run
  [ "$status" -eq 6 ]
  [ "$output" = "heartbeat: send failed (curl exit 6)" ]
  [ "$(fail_lines)" -eq 1 ]
  rm -f "$ST" "$LOG"
  export ATST_TEST_CURL_EXIT=22
  hb_run
  [ "$status" -eq 22 ]
  [ "$output" = "heartbeat: send failed (curl exit 22)" ]
  [ "$(log_lines)" -eq 1 ]
  [[ "$output" != *example.invalid* ]]
}

@test "HB-20: nothing under ~/.atst is written, no lock, no LINE push, no URL in other files (AC21)" {
  local l0 c0 e
  config_url "$U"
  set_status PROCESS_A 1
  line_fails 3 1
  for e in 0 6; do
    echo "case=exit $e"
    export ATST_TEST_CURL_EXIT=$e
    # the first run of common.sh may create files of its own (config exists already)
    l0=$(ls -A "$HOME/.atst"); c0=$(cksum "$ST" "$EL")
    hb_run
    [ "$(ls -A "$HOME/.atst")" = "$l0" ]
    [ "$(cksum "$ST" "$EL")" = "$c0" ]
    [ ! -e "$ST.lock" ]
    [ "$(atst_test_push_count)" -eq 0 ]
    [ -z "$(grep -rl example.invalid "$HOME/.atst" | grep -vE '/(config|\.heartbeat_url)$')" ]
  done
}

@test "HB-21: an empty ATST_ALERT_STATUS_FILE or an unreadable alert_status gives a ping silently" {
  config_url "$U"
  atst_test_set_config ATST_ALERT_STATUS_FILE ''
  set_status PROCESS_A 1
  hb_run
  [ "$status" -eq 0 ]
  [ "$(ping_lines)" -eq 1 ]
  [ -z "$output" ]
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode 000 file"
  config_url "$U"
  rm -f "$LOG"
  chmod 000 "$ST"
  hb_run
  chmod 600 "$ST"
  [ "$status" -eq 0 ]
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
  [ -z "$output" ]
}

@test "HB-22: arguments are ignored" {
  config_url "$U"
  set_status PROCESS_A 1
  hb_run foo bar
  [ "$status" -eq 0 ]
  [ "$(fail_lines)" -eq 1 ]
  [ -z "$output" ]
}

@test "HB-23: a cron-like minimal environment (env -i) gives the same /fail" {
  config_url "$U"
  set_status PROCESS_A 1
  run env -i HOME="$HOME" PATH="$BATS_TEST_DIRNAME/stubs:/usr/bin:/bin" ATST_TEST_CURL_LOG="$LOG" \
    bash "$BATS_TEST_DIRNAME/../heartbeat.sh"
  [ "$status" -eq 0 ]
  [ "$(fail_lines)" -eq 1 ]
  [ "$(fail_body)" = PROCESS_A ]
}

@test "HB-24: TICK_ (stopped ticks, #137) set to 0 gives a ping, not /fail" {
  config_url "$U"
  set_status TICK_A 0
  hb_run
  [ "$status" -eq 0 ]
  [ "$(ping_lines)" -eq 1 ]
  [ "$(fail_lines)" -eq 0 ]
}
