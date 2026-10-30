#!/usr/bin/env bats
# Reminders of an alert that goes on (#141): atst_update_alert sends "【継続中 <label>】<fire_msg>" once
# per stage of ATST_ALERT_REMIND_MINUTES (30 120 720 by default) while a PROCESS_* / MONITORING_* / TICK_* /
# RUNNER_STUCK key stays 1, and records the stage sent in the 4th column of alert_status only after a
# successful send. Inside a check_all.sh run the reminder goes to the spool as "1:remind=<stage>" and
# atst_spool_flush decides again by its stage. The time is made by writing a past epoch in the 3rd
# column (as tests/alert_update.bats does); the test IDs follow the acceptance criteria (RM-05 = AC5).

load test_helper

TOKEN=dummy-token-rm141-secret
LINEID=Udummy-id-rm141-secret

setup() {
  atst_test_setup_sandbox
  mkdir -p "$HOME/.atst"
  printf '%s\n' "$TOKEN" > "$HOME/.atst/.line_token"
  printf '%s\n' "$LINEID" > "$HOME/.atst/.line_id"
  atst_test_source_common
  ST=$ATST_ALERT_STATUS_FILE
  H=$(hostname -s)
  JQ=$(command -v jq)
}

teardown() {
  local pid
  pid=$(cat "$ATST_TEST_SANDBOX/holder.pid" 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null ;;
  esac
  atst_test_teardown_sandbox
}

# ago <minutes>: the epoch <minutes> minutes ago.
ago() {
  echo $(( $(date +%s) - $1 * 60 ))
}

# sent <s>: how many recorded pushes contain <s>.
sent() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | grep -cF -- "$1" || true
  else
    echo 0
  fi
}

# payload <n>: the JSON of the n-th push recorded by the curl stub.
payload() {
  local line
  line=$(grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | sed -n "${1}p")
  printf '%s\n' "${line#* -d }"
}

# has_text <n> <s>: how many messages of the n-th push contain <s>.
has_text() {
  payload "$1" | "$JQ" --arg s "$2" '[.messages[].text | select(contains($s))] | length'
}

# Number of spool items ([0-9]* files) in the directory $1 (0 when it does not exist).
items_in() {
  if [ -d "$1" ]; then
    find "$1" -mindepth 1 -maxdepth 1 -name '[0-9]*' | wc -l
  else
    echo 0
  fi
}

# reconfig <value>: ATST_ALERT_REMIND_MINUTES=<value> in the sandbox config, read again.
reconfig() {
  atst_test_set_config ATST_ALERT_REMIND_MINUTES "$1"
  atst_test_source_common
}

# No Authorization header, token or ID in the curl log's headers (AC24, as U5 in alert_update.bats).
no_bearer() {
  [ ! -e "$ATST_TEST_CURL_LOG" ] && return 0
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG" || true)" -eq 0 ] && [ "$(grep -cF "$TOKEN" "$ATST_TEST_CURL_LOG" || true)" -eq 0 ]
}

# no_secret <text>: neither the token nor the ID appears in <text> (AC24).
no_secret() {
  [[ "$1" != *"$TOKEN"* ]] && [[ "$1" != *"$LINEID"* ]]
}

# Starts a process holding the lock on $1 and waits until it holds it (as in tests/alert_update.bats).
hold_lock() {
  local i
  ( exec 8>>"$1"; flock 8; exec sleep 30 ) >/dev/null 2>&1 </dev/null 3>&- &
  echo "$!" > "$ATST_TEST_SANDBOX/holder.pid"
  for i in $(seq 1 20); do
    flock -n "$1" true || return 0
    sleep 0.1
  done
  return 1
}

# A curl in front of tests/stubs/curl that takes 0.5 seconds, so two sends overlap.
make_slow_curl() {
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  {
    printf '#!/bin/bash\n'
    printf '%q 0.5\n' "$(command -v sleep)"
    printf 'exec %q "$@"\n' "$BATS_TEST_DIRNAME/stubs/curl"
  } > "$ATST_TEST_SANDBOX/bin/curl"
  chmod 755 "$ATST_TEST_SANDBOX/bin/curl"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
  hash -r
  [ "$(command -v curl)" = "$ATST_TEST_SANDBOX/bin/curl" ]
}

@test "RM-05: 29 minutes after the fire notice nothing is sent and the line is unchanged (AC5)" {
  local e
  e=$(ago 29)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(cat "$ST")" = "PROCESS_A,1,$e" ]
}

@test "RM-06: 31 minutes after, one reminder of 30 minutes; the 3rd column is kept and stage 1 recorded (AC6, AC18)" {
  local e
  e=$(ago 31)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【継続中 30 分】fire-a')" -eq 1 ]
  [ "$(sent '【発生】')" -eq 0 ]
  grep -qx "PROCESS_A,1,$e,1" "$ST"
  [ "$(wc -l < "$ST")" -eq 1 ]
  no_bearer
}

@test "RM-07: the same stage is never sent twice (AC7)" {
  local e
  e=$(ago 31)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$(atst_test_push_count)" -eq 1 ]
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qx "PROCESS_A,1,$e,1" "$ST"
  no_bearer
}

@test "RM-08: 121 minutes after with stage 1 sent, one reminder of 2 hours, once (AC8)" {
  local e
  e=$(ago 121)
  printf 'PROCESS_A,1,%s,1\n' "$e" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【継続中 2 時間】fire-a')" -eq 1 ]
  grep -qx "PROCESS_A,1,$e,2" "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$(atst_test_push_count)" -eq 1 ]
  no_bearer
}

@test "RM-09: 721 minutes after with stage 2 sent, 12 hours; with stage 3 sent, nothing more (AC9)" {
  local e
  e=$(ago 721)
  printf 'PROCESS_A,1,%s,2\n' "$e" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【継続中 12 時間】fire-a')" -eq 1 ]
  grep -qx "PROCESS_A,1,$e,3" "$ST"

  e=$(ago 1500)
  printf 'PROCESS_A,1,%s,3\n' "$e" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qx "PROCESS_A,1,$e,3" "$ST"
  no_bearer
}

@test "RM-10: stages reached together send the furthest only, and a later stage is still sent (AC10)" {
  local e
  e=$(ago 200)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【継続中 2 時間】fire-a')" -eq 1 ]
  [ "$(sent '【継続中 30 分】')" -eq 0 ]
  grep -qx "PROCESS_A,1,$e,2" "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$(atst_test_push_count)" -eq 1 ]

  e=$(ago 721)
  sed -i "s/^PROCESS_A,1,[0-9]*,2\$/PROCESS_A,1,$e,2/" "$ST"
  grep -qx "PROCESS_A,1,$e,2" "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(sent '【継続中 12 時間】fire-a')" -eq 1 ]
  grep -qx "PROCESS_A,1,$e,3" "$ST"
  no_bearer
}

@test "RM-11: RUNNER_STUCK and MONITORING_* are reminded with the text of the call (AC11)" {
  local e
  e=$(ago 31)
  printf 'RUNNER_STUCK,1,%s\n' "$e" > "$ST"
  run atst_update_alert RUNNER_STUCK 1 '【発生】X 1900 秒' '【復帰】X'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【継続中 30 分】X 1900 秒')" -eq 1 ]
  grep -qx "RUNNER_STUCK,1,$e,1" "$ST"

  printf 'MONITORING_B,1,%s\n' "$e" > "$ST"
  run atst_update_alert MONITORING_B 1 '【発生】fire-b' '【復帰】rec-b'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(sent '【継続中 30 分】fire-b')" -eq 1 ]
  [ "$(sent '【発生】fire-b')" -eq 0 ]
  grep -qx "MONITORING_B,1,$e,1" "$ST"
  no_bearer
}

@test "RM-11: a fire text without 【発生】 gets the label in front" {
  [ "$(atst_alert_remind_text 'abc' 30)" = '【継続中 30 分】abc' ]
  [ "$(atst_alert_remind_text '【発生】abc' 120)" = '【継続中 2 時間】abc' ]
  [ "$(atst_alert_remind_text '【発生】abc' 720)" = '【継続中 12 時間】abc' ]
  [ "$(atst_alert_remind_text '【発生】abc' 10)" = '【継続中 10 分】abc' ]
  [ "$(atst_alert_remind_text 'x【発生】abc' 90)" = '【継続中 90 分】x【発生】abc' ]
}

@test "RM-12: a recovery clears the stage and the next fire counts from the first stage again (AC12)" {
  local t0 t
  printf 'PROCESS_A,1,%s,3\n' "$(ago 1500)" > "$ST"
  run atst_update_alert PROCESS_A 0 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【復帰】rec-a')" -eq 1 ]
  grep -qE '^PROCESS_A,0,[0-9]+$' "$ST"

  t0=$(date +%s)
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(sent '【発生】fire-a')" -eq 1 ]
  grep -qE '^PROCESS_A,1,[0-9]+$' "$ST"
  t=$(atst_get_alert_status_time PROCESS_A)
  [ "$t" -ge "$t0" ]

  printf 'PROCESS_A,1,%s\n' "$(ago 31)" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 3 ]
  [ "$(sent '【継続中 30 分】fire-a')" -eq 1 ]
  grep -qE '^PROCESS_A,1,[0-9]+,1$' "$ST"
  no_bearer
}

@test "RM-13: keys that are not targets are never reminded (AC13)" {
  local k line
  for k in PRICE_A SPREAD_A PING_A TARGET_A RUNNER_TIMEOUT_CHECK_PROCESS RUNNER_TARGETS_EMPTY KEY; do
    line="$k,1,$(ago 1500)"
    printf '%s\n' "$line" > "$ST"
    run atst_update_alert "$k" 1 "【発生】fire-$k" "【復帰】rec-$k"
    [ "$status" -eq 0 ] || { echo "$k: status=$status"; false; }
    [ -z "$output" ] || { echo "$k: $output"; false; }
    [ "$(atst_test_push_count)" -eq 0 ] || { echo "$k: pushed"; false; }
    [ "$(cat "$ST")" = "$line" ] || { echo "$k: line changed"; false; }
  done
}

@test "RM-14: an empty ATST_ALERT_REMIND_MINUTES turns reminders off; \"10\" has one stage of 10 minutes (AC14)" {
  local e
  reconfig ""
  e=$(ago 1500)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(cat "$ST")" = "PROCESS_A,1,$e" ]

  reconfig " "
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]

  reconfig "10"
  e=$(ago 11)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【継続中 10 分】fire-a')" -eq 1 ]
  grep -qx "PROCESS_A,1,$e,1" "$ST"

  e=$(ago 121)
  sed -i "s/^PROCESS_A,1,[0-9]*,1\$/PROCESS_A,1,$e,1/" "$ST"
  grep -qx "PROCESS_A,1,$e,1" "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  no_bearer
}

@test "RM-15: an invalid ATST_ALERT_REMIND_MINUTES gives one line on stderr and the default; a missing line gives the default silently (AC15)" {
  local v n=0
  for v in abc "30 20" "1 2 3 4" "0" "30 30" "030"; do
    reconfig "$v"
    printf 'PROCESS_A,1,%s\n' "$(ago 31)" > "$ST"
    run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
    n=$(( n + 1 ))
    [ "$status" -eq 0 ] || { echo "[$v] status=$status"; false; }
    [ "$(printf '%s\n' "$output" | grep -c ATST_ALERT_REMIND_MINUTES)" -eq 1 ] || { echo "[$v] $output"; false; }
    [ "${#lines[@]}" -eq 1 ] || { echo "[$v] $output"; false; }
    no_secret "$output"
    [ "$(atst_test_push_count)" -eq "$n" ] || { echo "[$v] push=$(atst_test_push_count)"; false; }
    [ "$(sent '【継続中 30 分】fire-a')" -eq "$n" ]
    grep -qE '^PROCESS_A,1,[0-9]+,1$' "$ST"

    # A key that is not a target never reads the value.
    printf 'KEY,1,%s\n' "$(ago 1500)" > "$ST"
    run atst_update_alert KEY 1 '【発生】fire-k' '【復帰】rec-k'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "[$v] KEY: $output"; false; }
    # Nor does a transition.
    rm -f "$ST"
    run atst_update_alert PROCESS_Z 0 '【発生】fire-z' '【復帰】rec-z'
    [ -z "$output" ] || { echo "[$v] transition: $output"; false; }
  done

  # An existing user's config without the line: the default, nothing on stderr.
  sed -i '/^ATST_ALERT_REMIND_MINUTES=/d' "$HOME/.atst/config"
  [ "$(grep -c ATST_ALERT_REMIND_MINUTES= "$HOME/.atst/config")" -eq 0 ]
  atst_test_source_common
  [ -z "${ATST_ALERT_REMIND_MINUTES+x}" ]
  printf 'PROCESS_A,1,%s\n' "$(ago 31)" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq $(( n + 1 )) ]
  [ "$(sent '【継続中 30 分】fire-a')" -eq $(( n + 1 )) ]
  grep -qE '^PROCESS_A,1,[0-9]+,1$' "$ST"
  no_bearer
}

@test "RM-15: atst_alert_remind_minutes prints the stages, nothing when off, and the default otherwise" {
  unset ATST_ALERT_REMIND_MINUTES
  [ "$(atst_alert_remind_minutes)" = "30 120 720" ]
  ATST_ALERT_REMIND_MINUTES=""
  run atst_alert_remind_minutes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ATST_ALERT_REMIND_MINUTES="5 60"
  [ "$(atst_alert_remind_minutes)" = "5 60" ]
  ATST_ALERT_REMIND_MINUTES=$'30\n20'
  run atst_alert_remind_minutes
  [ "${lines[0]}" = "atst_update_alert: ATST_ALERT_REMIND_MINUTES is invalid; using 30 120 720" ]
  [ "${lines[1]}" = "30 120 720" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "RM-16: a failed send records no stage and returns 1; the next call sends and records (AC16)" {
  local e
  e=$(ago 31)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  export ATST_TEST_CURL_HTTP_CODE=500
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(cat "$ST")" = "PROCESS_A,1,$e" ]
  [ "$(grep -c 'LINE send failed' "$HOME/.atst/line_error.log")" -eq 1 ]
  no_secret "$output"
  no_secret "$(cat "$HOME/.atst/line_error.log")"

  unset ATST_TEST_CURL_HTTP_CODE
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qx "PROCESS_A,1,$e,1" "$ST"
  no_bearer
}

@test "RM-17: a 3rd column in the future or not a number sends nothing (AC17)" {
  local line
  line="PROCESS_A,1,$(( $(date +%s) + 600 ))"
  printf '%s\n' "$line" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(cat "$ST")" = "$line" ]

  printf 'PROCESS_A,1,x\n' > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(cat "$ST")" = "PROCESS_A,1,x" ]

  # A stage that cannot be read counts as none: one reminder at most.
  printf 'PROCESS_A,1,%s,x\n' "$(ago 31)" > "$ST"
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qE '^PROCESS_A,1,[0-9]+,1$' "$ST"
}

@test "RM-18: 3-column lines read as before and the 4th column changes no reader (AC18)" {
  printf 'KEY,1,0\n' > "$ST"
  [ -z "$(atst_alert_transition KEY 1)" ]
  [ "$(atst_get_alert_status KEY)" = "1" ]
  [ "$(atst_get_alert_status_time KEY)" = "0" ]
  run atst_update_alert KEY 1 f r
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(cat "$ST")" = "KEY,1,0" ]

  printf 'PROCESS_A,1,123,2\n' > "$ST"
  [ "$(atst_get_alert_status PROCESS_A)" = "1" ]
  [ "$(atst_get_alert_status_time PROCESS_A)" = "123" ]
  [ "$(atst_get_alert_status_field PROCESS_A 4 0)" = "2" ]
  [ -z "$(atst_alert_transition PROCESS_A 1)" ]
  [ "$(atst_alert_transition PROCESS_A 0)" = "0" ]
  printf 'PROCESS_A,1,123\n' > "$ST"
  [ "$(atst_get_alert_status_field PROCESS_A 4 0)" = "0" ]
}

@test "RM-18: atst_set_alert_stage keeps the 1st to 3rd columns and writes only a line that is 1" {
  printf 'A,1,5\nPROCESS_A,1,123\nB,0,7\n' > "$ST"
  atst_set_alert_stage PROCESS_A 2
  [ "$(cat "$ST")" = $'A,1,5\nPROCESS_A,1,123,2\nB,0,7' ]
  atst_set_alert_stage PROCESS_A 3
  grep -qx 'PROCESS_A,1,123,3' "$ST"
  run atst_set_alert_stage B 1
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  run atst_set_alert_stage NONE 1
  [ "$status" -eq 1 ]
  run atst_set_alert_stage PROCESS_A 4
  [ "$status" -eq 1 ]
  run atst_set_alert_stage '' 1
  [ "$status" -eq 1 ]
  [ "$(cat "$ST")" = $'A,1,5\nPROCESS_A,1,123,3\nB,0,7' ]
  [ -z "$(compgen -G "$ST.??????")" ]
  atst_set_alert_status PROCESS_A 1
  grep -qE '^PROCESS_A,1,[0-9]+$' "$ST"
}

@test "RM-19: a held lock of PROCESS_A does not delay a reminder of PROCESS_B (AC19)" {
  local t0 el rc=0
  hold_lock "$(atst_alert_lock_file PROCESS_A)"
  printf 'PROCESS_A,1,%s\nPROCESS_B,1,%s\n' "$(ago 31)" "$(ago 31)" > "$ST"
  t0=$(date +%s)
  atst_update_alert PROCESS_B 1 '【発生】fire-b' '【復帰】rec-b' || rc=$?
  el=$(( $(date +%s) - t0 ))
  [ "$rc" -eq 0 ]
  [ "$el" -lt 5 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【継続中 30 分】fire-b')" -eq 1 ]
  grep -qE '^PROCESS_B,1,[0-9]+,1$' "$ST"
  grep -qE '^PROCESS_A,1,[0-9]+$' "$ST"
  no_bearer
}

@test "RM-19: a spooled reminder whose key lock is held is left within the flush budget (AC19)" {
  local t0 el
  printf 'PROCESS_A,1,%s\n' "$(ago 31)" > "$ST"
  atst_spool_begin
  atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 1 ]
  hold_lock "$(atst_alert_lock_file PROCESS_A)"
  t0=$(date +%s)
  run atst_spool_flush 1
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 1 ]
  [ "$el" -le 12 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  grep -qE '^PROCESS_A,1,[0-9]+$' "$ST"
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
}

@test "RM-19: the same reminder from two processes at once is sent once and both return 0" {
  local i p1 p2 r1 r2 e
  make_slow_curl
  for i in 1 2 3; do
    rm -f "$ATST_TEST_CURL_LOG"
    e=$(ago 31)
    printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
    ( atst_update_alert PROCESS_A 1 '【発生】fire-a' r ) >/dev/null 2>&1 </dev/null 3>&- &
    p1=$!
    ( atst_update_alert PROCESS_A 1 '【発生】fire-a' r ) >/dev/null 2>&1 </dev/null 3>&- &
    p2=$!
    r1=0; wait "$p1" || r1=$?
    r2=0; wait "$p2" || r2=$?
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "round $i: push=$(atst_test_push_count)"; false; }
    grep -qx "PROCESS_A,1,$e,1" "$ST"
    [ "$r1" -eq 0 ] || { echo "round $i: r1=$r1"; false; }
    [ "$r2" -eq 0 ] || { echo "round $i: r2=$r2"; false; }
  done
}

@test "RM-20: in a spool run the reminder goes in the same push as the other notices and both are recorded (AC20)" {
  local e f
  e=$(ago 31)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  atst_spool_begin
  run atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 1 ]
  f=$(compgen -G "$ATST_NOTIFY_SPOOL/000001.*")
  cmp <(printf 'PROCESS_A\n1:remind=1\n【継続中 30 分】fire-a') "$f"
  grep -qx "PROCESS_A,1,$e" "$ST"

  atst_update_alert PROCESS_C 1 '【発生】fire-c' r
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 2 ]
  run atst_spool_flush 2
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(has_text 1 '【継続中 30 分】fire-a')" -eq 1 ]
  [ "$(has_text 1 '【発生】fire-c')" -eq 1 ]
  [ "$(payload 1 | "$JQ" -r '.messages[].text' | grep -o "【$H】" | wc -l)" -eq 1 ]
  grep -qx "PROCESS_A,1,$e,1" "$ST"
  grep -qE '^PROCESS_C,1,[0-9]+$' "$ST"
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
  no_bearer
}

@test "RM-21: a spooled reminder in a push answered 500 is not recorded and the items are removed (AC21)" {
  local e
  e=$(ago 31)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  atst_spool_begin
  atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  atst_update_alert PROCESS_C 1 '【発生】fire-c' r
  export ATST_TEST_CURL_HTTP_CODE=500
  run atst_spool_flush 2
  [ "$status" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(cat "$ST")" = "PROCESS_A,1,$e" ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
  no_secret "$output"
  no_secret "$(cat "$HOME/.atst/line_error.log")"
  no_bearer
}

@test "RM-22: a stage recorded by another run before the flush is not sent again (AC22)" {
  local e
  e=$(ago 31)
  printf 'PROCESS_A,1,%s\n' "$e" > "$ST"
  atst_spool_begin
  atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  atst_update_alert PROCESS_C 1 '【発生】fire-c' r
  printf 'PROCESS_A,1,%s,1\n' "$e" > "$ST"
  run atst_spool_flush 2
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(has_text 1 '【発生】fire-c')" -eq 1 ]
  [ "$(has_text 1 '継続中')" -eq 0 ]
  grep -qx "PROCESS_A,1,$e,1" "$ST"
  no_bearer
}

@test "RM-23: a recovery recorded before the flush drops the reminder and never turns it into a fire (AC23)" {
  local line
  printf 'PROCESS_A,1,%s\n' "$(ago 31)" > "$ST"
  atst_spool_begin
  atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  line="PROCESS_A,0,$(date +%s)"
  printf '%s\n' "$line" > "$ST"
  run atst_spool_flush 2
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(cat "$ST")" = "$line" ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
}

@test "RM-SP: atst_spool_add takes 1:remind=1-3 only, and the flush skips another remind verdict as broken" {
  atst_spool_begin
  run atst_spool_add K '1:remind=1' t
  [ "$status" -eq 0 ]
  run atst_spool_add K '1:remind=3' t
  [ "$status" -eq 0 ]
  local v
  for v in '1:remind=4' '1:remind=' '1:x' '0:remind=1' '1:remind=1 '; do
    run atst_spool_add K "$v" t
    [ "$status" -eq 1 ] || { echo "[$v]"; false; }
    [ -n "$output" ]
  done
  run atst_spool_add '' '1:remind=1' t
  [ "$status" -eq 1 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 2 ]

  rm -f "$ATST_NOTIFY_SPOOL"/[0-9]*
  printf 'PROCESS_A,1,%s\n' "$(ago 1500)" > "$ST"
  printf 'PROCESS_A\n1:remind=9\n【継続中 30 分】BAD' > "$ATST_NOTIFY_SPOOL/000001.bad"
  run atst_spool_flush 2
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'broken item')" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  grep -qE '^PROCESS_A,1,[0-9]+$' "$ST"
}

@test "RM-SP: a reminder item flushed with reminders turned off is not sent" {
  printf 'PROCESS_A,1,%s\n' "$(ago 31)" > "$ST"
  atst_spool_begin
  atst_update_alert PROCESS_A 1 '【発生】fire-a' '【復帰】rec-a'
  ATST_ALERT_REMIND_MINUTES=""
  run atst_spool_flush 2
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  grep -qE '^PROCESS_A,1,[0-9]+$' "$ST"
}

@test "RM-SP: atst_set_alert_stage with an empty ATST_ALERT_STATUS_FILE returns 1 and creates nothing (#110)" {
  printf 'PROCESS_A,1,%s\n' "$(ago 31)" > "$ST"
  mkdir "$ATST_TEST_SANDBOX/cwd"
  cd "$ATST_TEST_SANDBOX/cwd"
  ATST_ALERT_STATUS_FILE=""
  run atst_set_alert_stage PROCESS_A 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'ATST_ALERT_STATUS_FILE is empty'* ]]
  [ -z "$(ls -A)" ]
  grep -qE '^PROCESS_A,1,[0-9]+$' "$ST"
}

@test "RM-25: TICK_* (stopped ticks, #137) is reminded like PROCESS_*" {
  local e
  e=$(ago 31)
  printf 'TICK_A,1,%s\n' "$e" > "$ST"
  run atst_update_alert TICK_A 1 '【発生】fire-t' '【復帰】rec-t'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(sent '【継続中 30 分】fire-t')" -eq 1 ]
  [ "$(grep -c "^TICK_A,1,$e,1$" "$ST")" -eq 1 ]
  no_bearer
}

@test "RM-26: XTICK_A, tick_a and RUNNER_TIMEOUT_CHECK_TICK are not reminded (#137)" {
  local k line
  for k in XTICK_A tick_a RUNNER_TIMEOUT_CHECK_TICK; do
    line="$k,1,$(ago 1500)"
    printf '%s\n' "$line" > "$ST"
    run atst_update_alert "$k" 1 '【発生】x' r
    [ "$status" -eq 0 ] || { echo "$k: status=$status"; false; }
    [ "$(atst_test_push_count)" -eq 0 ] || { echo "$k: pushed"; false; }
    [ "$(cat "$ST")" = "$line" ] || { echo "$k: line changed"; false; }
  done
}

@test "RM-27: atst_alert_remind_is_target takes TICK_* by its exact prefix (#137)" {
  local k
  for k in TICK_A TICK_A_B PROCESS_A; do
    run atst_alert_remind_is_target "$k"
    [ "$status" -eq 0 ] || { echo "$k: status=$status"; false; }
    [ -z "$output" ]
  done
  for k in XTICK_A tick_a RUNNER_TIMEOUT_CHECK_TICK ''; do
    run atst_alert_remind_is_target "$k"
    [ "$status" -eq 1 ] || { echo "$k: status=$status"; false; }
    [ -z "$output" ]
  done
  run atst_alert_remind_is_target
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
