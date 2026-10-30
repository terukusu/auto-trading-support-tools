#!/usr/bin/env bats
# Notices of one check_all.sh run in one LINE push (#96): the checks add their notices to the run's
# spool (atst_update_alert / atst_notify_text), and the runner sends them together (atst_spool_flush),
# recording a key only when its push succeeded. Outside a run (a check started directly,
# send_to_line.sh, a value in ~/.atst/config) everything is sent at once as before.
# The runner runs from a copy of the repository in the sandbox (atst_test_make_runner_home) whose
# checks are recording stubs unless a test puts the real one back or writes its own. The function
# tests read common.sh in the test itself (atst_test_source_common).

load ../test_helper

CHECKS="check_reboot check_order check_process check_monitoring check_tick check_trade_ready check_ping check_price check_spread heartbeat"

setup() {
  local n
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  home=$(atst_test_make_runner_home)
  atst_test_set_config ATST_CHECK_TIMEOUT 2
  atst_test_set_config ATST_ORDER_CHECK_INTERVAL 0
  for n in $CHECKS; do
    atst_test_stub_script "$home" "$n.sh" record
  done
  CALLS="$ATST_TEST_SANDBOX/calls.log"
  ST="$HOME/.atst/alert_status"
  SP="$HOME/.atst/check_all.spool"
  H=$(hostname -s)
  JQ=$(command -v jq)
}

teardown() {
  local f pid
  for f in holder.pid bg.pid; do
    pid=$(cat "$ATST_TEST_SANDBOX/$f" 2>/dev/null)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        ;;
    esac
  done
  chmod -R u+rwx "$ATST_TEST_SANDBOX" 2>/dev/null
  atst_test_teardown_sandbox
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

# The texts of every push, in push and message order.
all_texts() {
  local n
  for n in $(seq 1 "$(atst_test_push_count)"); do
    payload "$n" | "$JQ" -r '.messages[].text'
  done
}

# Number of alert_status lines matching the regex $1 (0 without the file).
status_lines() {
  if [ -e "$ST" ]; then
    grep -c "$1" "$ST"
  else
    echo 0
  fi
}

# Number of spool items ([0-9]* files) in the directory $1 (0 when it does not exist).
items_in() {
  if [ -d "$1" ]; then
    find "$1" -mindepth 1 -maxdepth 1 -name '[0-9]*' | wc -l
  else
    echo 0
  fi
}

reboot_seen() {
  echo '9999999999.00 0.00' > "$HOME/.atst/uptime"
}

# Starts a process holding the lock on $1 (as another process would) and waits until it holds it.
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

# A PATH with every command except jq (as L5 in send_to_line.bats), the stubs first.
nojq_path() {
  local nojq="$ATST_TEST_SANDBOX/nojq" d
  if [ ! -d "$nojq" ]; then
    mkdir -p "$nojq"
    local IFS=:
    for d in $PATH; do
      [ -d "$d" ] || continue
      find "$d" -mindepth 1 -maxdepth 1 ! -name jq -exec ln -s -t "$nojq" {} + 2>/dev/null || true
    done
    unset IFS
  fi
  printf '%s\n' "$BATS_TEST_DIRNAME/../stubs:$nojq"
}

# Spools 12 notices of about 2000 characters (K01 .. K12: 2 per message, 6 messages).
spool_twelve() {
  local i body
  body=$(printf 'あ%.0s' $(seq 1 2000))
  for i in $(seq -w 1 12); do
    atst_update_alert "K$i" 1 "【発生】K$i:$body" r
    [ "$(atst_test_push_count)" -eq 0 ]
  done
}

# The labels K01: .. found in the texts of push $1, in order.
labels_of() {
  payload "$1" | "$JQ" -r '.messages[].text' | grep -o 'K[0-9][0-9]:' | tr -d '\n'
}

# A runner setup where MT_A and MT_B have no process, MT_A's monitoring data is old and a reboot is seen.
three_events() {
  cp -p "$repo/check_reboot.sh" "$repo/check_process.sh" "$repo/check_monitoring.sh" "$home/"
  atst_test_make_mt MT_A MT4
  atst_test_make_mt MT_B MT4
  atst_test_make_monitoring_csv MT_A 500 150.0 10 0.01
  atst_test_make_monitoring_csv MT_B 0 150.0 10 0.01
  atst_test_set_targets MT_A MT_B
  reboot_seen
}

@test "NB-01: notices of one run reach LINE in one push, in run order, recorded, and not again (AC1)" {
  local t
  three_events
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(payload 1 | "$JQ" '.messages | length')" -eq 1 ]
  t=$(payload 1 | "$JQ" -r '.messages[0].text')
  [[ "$t" == "【$H】"* ]]
  [[ "$t" == *'サーバーの再起動を検出しました'*'【発生】MetaTraderプロセスが動作していません: MT_A'*'【発生】MetaTraderプロセスが動作していません: MT_B'*'【発生】MT_A のモニタリングデータが'* ]]
  [[ "$t" == *$'\n\n【発生】MetaTraderプロセスが動作していません: MT_A'* ]]
  [ "$(grep -o "【$H】" <<< "$t" | wc -l)" -eq 1 ]
  [ "$(status_lines '^PROCESS_.*,1,')" -eq 2 ]
  [ "$(status_lines '^MONITORING_.*,1,')" -eq 1 ]
  [ ! -e "$SP" ]

  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "NB-02: a push answered 500 records nothing; the next run sends again and records (AC2)" {
  local t
  three_events
  export ATST_TEST_CURL_HTTP_CODE=500
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^PROCESS_\|^MONITORING_')" -eq 0 ]
  [ "$(grep -c 'http=500' "$HOME/.atst/line_error.log")" -eq 1 ]
  [ ! -e "$SP" ]
  # The uptime is recorded whether the send worked or not.
  [ "$(cut -d. -f1 "$HOME/.atst/uptime")" -lt 9999999999 ]

  unset ATST_TEST_CURL_HTTP_CODE
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(status_lines '^PROCESS_.*,1,')" -eq 2 ]
  [ "$(status_lines '^MONITORING_.*,1,')" -eq 1 ]
  t=$(payload 2 | "$JQ" -r '.messages[].text')
  [[ "$t" == *'【発生】MetaTraderプロセスが動作していません: MT_A'* ]]
  [[ "$t" != *'サーバーの再起動を検出しました'* ]]
}

@test "NB-02: a push answered 400 records nothing either (AC2)" {
  three_events
  export ATST_TEST_CURL_HTTP_CODE=400
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^PROCESS_\|^MONITORING_')" -eq 0 ]
}

@test "NB-03: a check run directly or send_to_line.sh sends at once without a spool (AC3)" {
  atst_test_make_mt MT_A MT4
  run bash "$repo/check_process.sh" MT_A
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^PROCESS_MT_A,1,')" -eq 1 ]
  [ ! -e "$SP" ]

  rm -f "$ATST_TEST_CURL_LOG"
  run bash -c 'echo hello | bash "$1"' _ "$repo/send_to_line.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ ! -e "$SP" ]
}

@test "NB-03: ATST_NOTIFY_SPOOL in ~/.atst/config is ignored: the check still sends at once (AC3)" {
  atst_test_make_mt MT_A MT4
  mkdir -p "$SP/run.1.1"
  chmod 700 "$SP" "$SP/run.1.1"
  atst_test_set_config ATST_NOTIFY_SPOOL "$SP/run.1.1"
  run bash "$repo/check_process.sh" MT_A
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ -z "$(ls -A "$SP/run.1.1")" ]
  [ "$(status_lines '^PROCESS_MT_A,1,')" -eq 1 ]
}

@test "NB-03: an ATST_NOTIFY_SPOOL that is not a run's spool is not used (AC3)" {
  local v
  atst_test_make_mt MT_A MT4
  mkdir -p "$SP/run.1.1" "$SP/x" "$ATST_TEST_SANDBOX/other/check_all.spool/run.1.1"
  chmod 700 "$SP" "$SP/run.1.1"
  ln -s "$SP/run.1.1" "$SP/run.2.2"
  for v in "$SP/run.9.9" "$SP/x" "$SP/run.1.1/" check_all.spool/run.1.1 "$SP/run.2.2" \
    "$ATST_TEST_SANDBOX/other/check_all.spool/run.1.1"; do
    rm -f "$ST" "$ATST_TEST_CURL_LOG"
    ATST_NOTIFY_SPOOL="$v" run bash "$repo/check_process.sh" MT_A
    [ "$status" -eq 0 ] || { echo "$v: status=$status"; return 1; }
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "$v: push=$(atst_test_push_count)"; return 1; }
  done
  [ "$(items_in "$SP/run.1.1")" -eq 0 ]
  [ "$(items_in "$SP/x")" -eq 0 ]
  [ "$(items_in "$ATST_TEST_SANDBOX/other/check_all.spool/run.1.1")" -eq 0 ]
}

@test "NB-04: a transition sent and recorded by another run after it was spooled is not sent again (AC4)" {
  atst_test_make_mt MT_A MT4
  atst_test_set_targets MT_A
  cat > "$home/check_process.sh" <<EOF
#!/bin/bash
. "$home/common.sh"
atst_update_alert PROCESS_MT_A 1 "【発生】MetaTraderプロセスが動作していません: MT_A" "【復帰】MetaTraderプロセスが再開しました: MT_A"
find "\$ATST_NOTIFY_SPOOL" -mindepth 1 -maxdepth 1 -name '[0-9]*' | wc -l > "$ATST_TEST_SANDBOX/items"
if [ -e "\$ATST_TEST_CURL_LOG" ]; then grep -c 'message/push' "\$ATST_TEST_CURL_LOG"; else echo 0; fi > "$ATST_TEST_SANDBOX/push_at_spool"
env -u ATST_NOTIFY_SPOOL bash "$repo/check_process.sh" "\$@"
EOF
  chmod 755 "$home/check_process.sh"
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$ATST_TEST_SANDBOX/items")" -eq 1 ]
  [ "$(cat "$ATST_TEST_SANDBOX/push_at_spool")" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -o 'プロセスが動作していません: MT_A' "$ATST_TEST_CURL_LOG" | wc -l)" -eq 1 ]
  [ "$(status_lines '^PROCESS_MT_A,')" -eq 1 ]
  [ "$(status_lines '^PROCESS_MT_A,1,')" -eq 1 ]
}

@test "NB-05: a notice spooled by a check cut off later reaches LINE with the cut-off notice (AC5)" {
  local t0 el
  atst_test_set_targets A
  cat > "$home/check_process.sh" <<EOF
#!/bin/bash
. "$home/common.sh"
atst_update_alert SPOOLED_X 1 "【発生】SPOOLTEST_X" "【復帰】SPOOLTEST_X"
exec sleep 300
EOF
  chmod 755 "$home/check_process.sh"
  t0=$(date +%s)
  run timeout 60 bash "$home/check_all.sh"
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 12 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(has_text 1 '【発生】SPOOLTEST_X')" -eq 1 ]
  [ "$(has_text 1 '【発生】チェックが 2 秒で終わらず打ち切りました: check_process.sh')" -eq 1 ]
  [ "$(status_lines '^SPOOLED_X,1,')" -eq 1 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_PROCESS,1,')" -eq 1 ]
  [ ! -e "$SP" ]
  run pgrep -f "$home/check_process.sh"
  [ "$status" -ne 0 ]
}

@test "NB-06: what an earlier run left in the spool is never sent nor recorded, and is removed (AC6)" {
  cp -p "$repo/check_reboot.sh" "$home/"
  atst_test_set_targets A
  mkdir -p "$SP/run.1.1"
  chmod 700 "$SP" "$SP/run.1.1"
  printf 'STALE_X\n1\n【発生】STALE_TEXT' > "$SP/run.1.1/000001.abcdef"
  printf 'STALE_Y\n1\n【発生】STALE_ROOT' > "$SP/000001.zz"
  reboot_seen
  export ATST_NOTIFY_SPOOL="$SP/run.1.1"
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c STALE "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(status_lines '^STALE_')" -eq 0 ]
  [ ! -e "$SP" ]
  [ "$(has_text 1 'サーバーの再起動を検出しました')" -eq 1 ]
}

@test "NB-07: 6 messages go in 2 pushes of at most 5, each text at most 4900, notices whole and in order (AC7)" {
  local i n body
  atst_test_source_common
  atst_spool_begin
  [ -n "$ATST_NOTIFY_SPOOL" ]
  spool_twelve
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 12 ]
  [[ "$(ls "$ATST_NOTIFY_SPOOL" | head -1)" == 000001.* ]]
  [[ "$(ls "$ATST_NOTIFY_SPOOL" | tail -1)" == 000012.* ]]
  [ ! -e "$ATST_TEST_CURL_LOG" ]

  run atst_spool_flush 2
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(payload 1 | "$JQ" '.messages | length')" -le 5 ]
  [ "$(payload 2 | "$JQ" '.messages | length')" -le 5 ]
  for n in 1 2; do
    [ "$(payload "$n" | "$JQ" '[.messages[].text | length] | max')" -le 4900 ]
    [ "$(payload "$n" | "$JQ" --arg h "【$H】" '[.messages[].text | select(startswith($h) | not)] | length')" -eq 0 ]
  done
  body=$(printf 'あ%.0s' $(seq 1 2000))
  for i in $(seq -w 1 12); do
    [ "$(( $(has_text 1 "【発生】K$i:$body") + $(has_text 2 "【発生】K$i:$body") ))" -eq 1 ] || { echo "K$i"; return 1; }
  done
  [ "$(all_texts | grep -o 'K[0-9][0-9]:' | tr -d '\n')" = "K01:K02:K03:K04:K05:K06:K07:K08:K09:K10:K11:K12:" ]
  [ "$(status_lines '^K[0-9][0-9],1,')" -eq 12 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]

  atst_spool_end
  [ ! -e "$SP" ]
  [ -z "${ATST_NOTIFY_SPOOL+x}" ]
}

@test "NB-07: when only the second push fails, only the keys of the first are recorded (AC7)" {
  local k first second
  atst_test_source_common
  atst_spool_begin
  spool_twelve
  [ ! -e "$ATST_TEST_CURL_LOG" ]
  export ATST_TEST_CURL_HTTP_CODE_SEQ="200 500"
  run atst_spool_flush 2
  [ "$status" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  first=$(labels_of 1)
  second=$(labels_of 2)
  [ -n "$first" ]
  [ -n "$second" ]
  for k in $(grep -o 'K[0-9][0-9]' <<< "$first"); do
    [ "$(status_lines "^$k,1,")" -eq 1 ] || { echo "$k"; return 1; }
  done
  for k in $(grep -o 'K[0-9][0-9]' <<< "$second"); do
    [ "$(status_lines "^$k,")" -eq 0 ] || { echo "$k"; return 1; }
  done
  [ "$(grep -c 'http=500' "$HOME/.atst/line_error.log")" -eq 1 ]
}

@test "NB-07: a notice longer than one message is cut alone, the next one goes in its own message (AC7)" {
  local big t
  atst_test_source_common
  atst_spool_begin
  big=$(printf 'い%.0s' $(seq 1 6000))
  atst_update_alert BIG 1 "$big" r
  atst_update_alert SMALL 1 "【発生】SMALL" r
  run atst_spool_flush 2
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(payload 1 | "$JQ" '.messages | length')" -eq 2 ]
  t=$(payload 1 | "$JQ" -r '.messages[0].text')
  [[ "$t" == *'…(以下省略)' ]]
  [ "$(payload 1 | "$JQ" '.messages[0].text | length')" -le 4900 ]
  [ "$(payload 1 | "$JQ" -r '.messages[1].text')" = "【$H】【発生】SMALL" ]
  [ "$(status_lines '^BIG,1,')" -eq 1 ]
  [ "$(status_lines '^SMALL,1,')" -eq 1 ]
}

@test "NB-08: without jq the flushed payload is valid JSON with the same texts (AC7)" {
  local t1 t2 with without
  t1=$'a"b/c\\d\nx'
  t2='【発生】日本語'
  PATH="$(nojq_path)" run bash -c '. "$1/common.sh"; [ -z "$(command -v jq)" ] || exit 9; atst_spool_begin && printf "%s" "$2" | atst_notify_text && atst_update_alert K1 1 "$3" r && atst_spool_flush 2' _ "$repo" "$t1" "$t2"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  payload 1 | "$JQ" -e . >/dev/null
  # atst_escape_text escapes "/" (jq does not): the jq-less branch was taken.
  payload 1 | grep -qF 'b\/c'
  without=$(payload 1 | "$JQ" -c '[.messages[].text]')
  [ "$(payload 1 | "$JQ" -r .to)" = "$(bash -c '. "$1/common.sh"; printf %s "$ATST_LINE_ID"' _ "$repo")" ]

  mv "$ATST_TEST_CURL_LOG" "$ATST_TEST_SANDBOX/nojq.log"
  rm -f "$ST"
  run bash -c '. "$1/common.sh"; atst_spool_begin && printf "%s" "$2" | atst_notify_text && atst_update_alert K1 1 "$3" r && atst_spool_flush 2' _ "$repo" "$t1" "$t2"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  with=$(payload 1 | "$JQ" -c '[.messages[].text]')
  [ "$without" = "$with" ]
  [ "$(payload 1 | "$JQ" -r '.messages[0].text')" = "【$H】$t1"$'\n\n'"$t2" ]
}

@test "NB-09: past max_pushes nothing more is sent nor recorded, and the rest is removed (AC7)" {
  local k first
  atst_test_source_common
  atst_spool_begin
  spool_twelve
  run atst_spool_flush 1
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  first=$(labels_of 1)
  for k in $(seq -w 1 12); do
    if [[ "$first" == *"K$k:"* ]]; then
      [ "$(status_lines "^K$k,1,")" -eq 1 ] || { echo "K$k"; return 1; }
    else
      [ "$(status_lines "^K$k,")" -eq 0 ] || { echo "K$k"; return 1; }
    fi
  done
  [ "$(status_lines '^K')" -lt 12 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
}

@test "NB-09: an invalid max_pushes returns 2 and does nothing" {
  local v
  atst_test_source_common
  atst_spool_begin
  atst_update_alert K1 1 '【発生】K1' r
  for v in 0 abc -1 ''; do
    run atst_spool_flush "$v"
    [ "$status" -eq 2 ] || { echo "$v: $status"; return 1; }
  done
  run atst_spool_flush
  [ "$status" -eq 2 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 1 ]
}

@test "NB-10: the runner's own notices go in the same push as the others (AC8)" {
  cp -p "$repo/check_reboot.sh" "$home/"
  sed -i '/^ATST_TARGETS=/d' "$HOME/.atst/config"
  reboot_seen
  printf 'RUNNER_STUCK,1,0\n' > "$ST"
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(has_text 1 '【発生】監視対象が設定されていません')" -eq 1 ]
  [ "$(has_text 1 'サーバーの再起動を検出しました')" -eq 1 ]
  [ "$(has_text 1 '【復帰】毎分の監視 (check_all.sh) が再開しました')" -eq 1 ]
  [ "$(status_lines '^RUNNER_TARGETS_EMPTY,1,')" -eq 1 ]
  [ "$(status_lines '^RUNNER_STUCK,0,')" -eq 1 ]
}

@test "NB-11: a usual run's push goes out before the second check_order (AC9)" {
  atst_test_set_targets A
  atst_test_set_config ATST_ORDER_CHECK_INTERVAL 3
  cat > "$home/check_order.sh" <<EOF
#!/bin/bash
if [ -e "\$ATST_TEST_CURL_LOG" ]; then grep -c 'message/push' "\$ATST_TEST_CURL_LOG"; else echo 0; fi >> "$ATST_TEST_SANDBOX/order_push.log"
exit 0
EOF
  cat > "$home/check_process.sh" <<EOF
#!/bin/bash
. "$home/common.sh"
atst_update_alert P_X 1 "【発生】P_X" r
EOF
  chmod 755 "$home/check_order.sh" "$home/check_process.sh"
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$ATST_TEST_SANDBOX/order_push.log")" = "$(printf '0\n1')" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^P_X,1,')" -eq 1 ]
}

@test "NB-12: keys sharing a lock file do not block each other, and the last notice of a key wins" {
  local t0 el
  atst_test_source_common
  atst_spool_begin
  atst_update_alert 'A B' 1 '【発生】AB_SPACE' r
  atst_update_alert A_B 1 '【発生】AB_UNDER' r
  atst_update_alert DUP 1 '【発生】DUP_OLD' r
  atst_update_alert DUP 1 '【発生】DUP_NEW' r
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 4 ]
  t0=$(date +%s)
  run atst_spool_flush 2
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 5 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(has_text 1 'AB_SPACE')" -eq 1 ]
  [ "$(has_text 1 'AB_UNDER')" -eq 1 ]
  [ "$(has_text 1 'DUP_NEW')" -eq 1 ]
  [ "$(has_text 1 'DUP_OLD')" -eq 0 ]
  [ "$(grep -c '^A B,1,' "$ST")" -eq 1 ]
  [ "$(grep -c '^A_B,1,' "$ST")" -eq 1 ]
  [ "$(grep -c '^DUP,1,' "$ST")" -eq 1 ]
}

@test "NB-13: a key whose lock is held elsewhere is left for the next run within the 10-second budget" {
  local t0 el
  atst_test_source_common
  hold_lock "$(atst_alert_lock_file HELD)"
  atst_spool_begin
  atst_update_alert HELD 1 '【発生】HELD_TEXT' r
  atst_update_alert FREE 1 '【発生】FREE_TEXT' r
  t0=$(date +%s)
  run atst_spool_flush 2
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 1 ]
  [ "$el" -le 15 ]
  [ -n "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(has_text 1 'FREE_TEXT')" -eq 1 ]
  [ "$(has_text 1 'HELD_TEXT')" -eq 0 ]
  [ "$(status_lines '^FREE,1,')" -eq 1 ]
  [ "$(status_lines '^HELD,')" -eq 0 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
}

@test "NB-14: atst_spool_add writes one whole item with private modes and leaves no temporary file" {
  local f
  atst_test_source_common
  atst_spool_begin
  atst_spool_add K 1 $'l1\nl2'
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 1 ]
  [ -z "$(compgen -G "$ATST_NOTIFY_SPOOL/.tmp.*" || true)" ]
  f=$(compgen -G "$ATST_NOTIFY_SPOOL/000001.*")
  cmp <(printf 'K\n1\nl1\nl2') "$f"
  [ "$(stat -c %a "$SP")" = 700 ]
  [ "$(stat -c %a "$ATST_NOTIFY_SPOOL")" = 700 ]
  [ "$(stat -c %a "$f")" = 600 ]
}

@test "NB-14: atst_spool_add refuses a key with a line break, a bad verdict, a verdict without a key" {
  local saved
  atst_test_source_common
  atst_spool_begin
  run atst_spool_add $'A\nB' 1 t
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  run atst_spool_add $'A\rB' 1 t
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  run atst_spool_add K x t
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  run atst_spool_add '' 1 t
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]

  # A key with a line break is sent at once by atst_update_alert.
  run atst_update_alert $'A\nB' 1 '【発生】NEWLINE_KEY' r
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]

  saved=$ATST_NOTIFY_SPOOL
  unset ATST_NOTIFY_SPOOL
  run atst_spool_add K 1 t
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(items_in "$saved")" -eq 0 ]
}

@test "NB-14: the flush never sends a .tmp file or a broken item" {
  atst_test_source_common
  atst_spool_begin
  printf 'K2\n1\n【発生】TMPTEXT' > "$ATST_NOTIFY_SPOOL/.tmp.abcdef"
  printf 'K3\nx\n【発生】BADTEXT' > "$ATST_NOTIFY_SPOOL/000050.bad"
  atst_update_alert K4 1 '【発生】K4TEXT' r
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 2 ]
  [ -n "$(compgen -G "$ATST_NOTIFY_SPOOL/000051.*")" ]
  run atst_spool_flush 2
  [ "$status" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c 'TMPTEXT\|BADTEXT' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(has_text 1 'K4TEXT')" -eq 1 ]
  [ "$(status_lines '^K2,\|^K3,')" -eq 0 ]
  [ "$(status_lines '^K4,1,')" -eq 1 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
}

@test "NB-14: when the spool cannot be written, the notice is sent at once" {
  [ "$EUID" -ne 0 ] || skip "root can write a read-only directory"
  atst_test_source_common
  atst_spool_begin
  chmod 500 "$ATST_NOTIFY_SPOOL"
  run atst_update_alert K5 1 '【発生】K5' r
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^K5,1,')" -eq 1 ]
  printf 'NT\n' | atst_notify_text
  [ "$(atst_test_push_count)" -eq 2 ]
  chmod 700 "$ATST_NOTIFY_SPOOL"
}

@test "NB-14: a notice no longer due when flushed is not sent" {
  atst_test_source_common
  atst_spool_begin
  atst_update_alert K6 1 '【発生】K6' r
  printf 'K6,1,0\n' >> "$ST"
  run atst_spool_flush 2
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "NB-15: the curl stub answers the codes of ATST_TEST_CURL_HTTP_CODE_SEQ in order" {
  local out
  out=$(curl -s -w x; echo .)
  [ "$out" = $'\n200.' ]
  out=$(ATST_TEST_CURL_HTTP_CODE=404 curl -s -w x; echo .)
  [ "$out" = $'\n404.' ]
  rm -f "$ATST_TEST_CURL_LOG"
  export ATST_TEST_CURL_HTTP_CODE=404 ATST_TEST_CURL_HTTP_CODE_SEQ="200 500"
  [ "$(curl -w x)" = $'\n200' ]
  [ "$(curl -w x)" = $'\n500' ]
  [ "$(curl -w x)" = $'\n404' ]
  [ "$(wc -l < "$ATST_TEST_CURL_LOG")" -eq 3 ]
  rm -f "$ATST_TEST_CURL_LOG"
  ATST_TEST_CURL_HTTP_CODE_SEQ="" run curl -w x
  [ "$output" = $'\n404' ]
  run env -u ATST_TEST_CURL_LOG curl -w x
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "NB-16: a single flushed notice is the same text atst_send_to_line sends" {
  local t0
  atst_test_source_common
  printf '【発生】ONE\nline2\n' | atst_send_to_line
  t0=$(payload 1 | "$JQ" -r '.messages[0].text')
  rm -f "$ATST_TEST_CURL_LOG"
  atst_spool_begin
  atst_update_alert ONE 1 $'【発生】ONE\nline2' r
  run atst_spool_flush 2
  [ "$status" -eq 0 ]
  [ "$(payload 1 | "$JQ" '.messages | length')" -eq 1 ]
  [ "$(payload 1 | "$JQ" -r '.messages[0].text')" = "$t0" ]
}

@test "NB-16: atst_notify_text sends at once without a spool and spools a text-only item with one" {
  local f
  atst_test_source_common
  printf 'NT\n' | atst_notify_text
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(payload 1 | "$JQ" -r '.messages[0].text')" = "【$H】NT" ]
  atst_spool_begin
  printf 'NT\n' | atst_notify_text
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 1 ]
  f=$(compgen -G "$ATST_NOTIFY_SPOOL/000001.*")
  cmp <(printf '\n\nNT') "$f"
}

@test "NB-16: atst_spool_begin failing returns 1 and leaves no spool; atst_spool_end is repeatable" {
  local saved
  atst_test_source_common
  : > "$ATST_TEST_SANDBOX/file"
  saved=$ATST_CONFIG_DIR
  ATST_CONFIG_DIR="$ATST_TEST_SANDBOX/file/x"
  run atst_spool_begin
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  atst_spool_begin || true
  [ -z "${ATST_NOTIFY_SPOOL+x}" ]
  printf 'X\n' | atst_notify_text
  [ "$(atst_test_push_count)" -eq 1 ]
  ATST_CONFIG_DIR=$saved

  atst_spool_begin
  atst_spool_end
  atst_spool_end
  [ ! -e "$SP" ]
  [ -z "${ATST_NOTIFY_SPOOL+x}" ]
}

@test "NB-17: RUNNER_STUCK from a runner without the lock is sent at once, never into a spool (AC8)" {
  mkdir -p "$SP/run.1.1"
  chmod 700 "$SP" "$SP/run.1.1"
  export ATST_NOTIFY_SPOOL="$SP/run.1.1"
  hold_lock "$HOME/.atst/check_all.lock"
  echo "$(( $(date +%s) - 2000 ))" > "$HOME/.atst/check_all.started"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '【発生】毎分の監視 (check_all.sh) が' "$ATST_TEST_CURL_LOG"
  [ "$(status_lines '^RUNNER_STUCK,1,')" -eq 1 ]
  [ "$(items_in "$SP/run.1.1")" -eq 0 ]
  [ ! -e "$CALLS" ]
}

@test "NB-18: atst_line_texts_payload puts 1 to 5 texts in order and refuses other counts" {
  local out
  atst_test_source_common
  run atst_line_texts_payload U a 'b"c'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(printf '%s' "$output" | "$JQ" -r .to)" = U ]
  [ "$(printf '%s' "$output" | "$JQ" '.messages | length')" -eq 2 ]
  [ "$(printf '%s' "$output" | "$JQ" -r '.messages[1].text')" = 'b"c' ]
  [ "$(printf '%s' "$output" | "$JQ" '[.messages[] | select(.type != "text")] | length')" -eq 0 ]
  [ "$(atst_line_texts_payload U a 'b"c')" = "$output" ]
  [ "$(atst_line_texts_payload U 1 2 3 4 5 | "$JQ" -c '[.messages[].text]')" = '["1","2","3","4","5"]' ]
  run atst_line_texts_payload U
  [ "$status" -eq 2 ]
  out=$(atst_line_texts_payload U 2>/dev/null || true)
  [ -z "$out" ]
  run atst_line_texts_payload U 1 2 3 4 5 6
  [ "$status" -eq 2 ]
  out=$(atst_line_texts_payload U 1 2 3 4 5 6 2>/dev/null || true)
  [ -z "$out" ]

  PATH="$(nojq_path)" run bash -c '. "$1/common.sh"; [ -z "$(command -v jq)" ] || exit 9; atst_line_texts_payload U a "b\"c/" 3 4 5' _ "$repo"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | "$JQ" -c '[.messages[].text]')" = '["a","b\"c/","3","4","5"]' ]
  [ "$(printf '%s' "$output" | "$JQ" -r .to)" = U ]
}

@test "NB-19: atst_line_post returns 0/1/2 by the HTTP code, logs failures and keeps the token off argv" {
  local pl code rc
  atst_test_source_common
  pl='{"to":"x","messages":[{"type":"text","text":"t"}]}'
  run atst_line_post "$pl" t
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.atst/line_error.log" ]
  for code in 500:1 400:2 401:1 403:1 429:1; do
    ATST_TEST_CURL_HTTP_CODE=${code%:*} run atst_line_post "$pl" t
    rc=${code#*:}
    [ "$status" -eq "$rc" ] || { echo "$code: $status"; return 1; }
  done
  ATST_TEST_CURL_HTTP_CODE=000 ATST_TEST_CURL_EXIT=28 run atst_line_post "$pl" t
  [ "$status" -eq 1 ]
  [ "$(grep -c 'http=500' "$HOME/.atst/line_error.log")" -eq 1 ]
  [ "$(grep -c -- '--max-time 30' "$ATST_TEST_CURL_LOG")" -eq 7 ]
  [ "$(grep -c -- '--connect-timeout 10' "$ATST_TEST_CURL_LOG")" -eq 7 ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(payload 1)" = "$pl" ]
}

@test "NB-20: atst_send_to_line always sends at once; the lock file name is unchanged" {
  local f
  atst_test_source_common
  atst_spool_begin
  echo hi | atst_send_to_line
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
  [ "$(atst_alert_lock_file 'A B-c')" = "$HOME/.atst/alert_update.A_B_c.lock" ]
  [ ! -e "$HOME/.atst/alert_update.A_B_c.lock" ]
  f=$(atst_alert_lock_file "$(printf 'k%.0s' $(seq 1 250))")
  f=${f##*/alert_update.}
  f=${f%.lock}
  [ "${#f}" -eq 200 ]
}

@test "NB-21: a cut-off second check_order is reported in one more push at the end of the run" {
  local t0 el
  cp -p "$repo/check_reboot.sh" "$home/"
  reboot_seen
  atst_test_set_targets A
  cat > "$home/check_order.sh" <<EOF
#!/bin/bash
echo "check_order.sh \$(date +%s)" >> "$CALLS"
if [ "\$(grep -c '^check_order.sh ' "$CALLS")" -ge 2 ]; then
  exec sleep 300
fi
exit 0
EOF
  chmod 755 "$home/check_order.sh"
  t0=$(date +%s)
  run timeout 60 bash "$home/check_all.sh"
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 15 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(has_text 1 'サーバーの再起動を検出しました')" -eq 1 ]
  [ "$(has_text 1 '打ち切りました')" -eq 0 ]
  [ "$(has_text 2 '【発生】チェックが 2 秒で終わらず打ち切りました: check_order.sh')" -eq 1 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_ORDER,1,')" -eq 1 ]
  [ ! -e "$SP" ]
}

@test "NB-22: atst_spool_dir accepts only a run's spool and the config cannot set ATST_NOTIFY_SPOOL" {
  local run_dir v
  atst_test_source_common
  atst_spool_begin
  run_dir=$ATST_NOTIFY_SPOOL
  run atst_spool_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$run_dir" ]

  mkdir -p "$SP/x" "$SP/run.1" "$SP/run.a.1" "$ATST_TEST_SANDBOX/other/check_all.spool/run.1.1"
  ln -s "$run_dir" "$SP/run.2.2"
  for v in "" "$SP/run.9.9" "$SP/x" "$run_dir/" "$SP/run.1" "$SP/run.a.1" "$SP/run.2.2" \
    "$ATST_TEST_SANDBOX/other/check_all.spool/run.1.1"; do
    ATST_NOTIFY_SPOOL=$v run atst_spool_dir
    [ "$status" -eq 1 ] || { echo "$v: $status"; return 1; }
    [ -z "$output" ]
  done
  ( unset ATST_NOTIFY_SPOOL; ! atst_spool_dir )

  # check_all.spool itself a symlink.
  mv "$SP" "$ATST_TEST_SANDBOX/real_spool"
  ln -s "$ATST_TEST_SANDBOX/real_spool" "$SP"
  run atst_spool_dir
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  atst_test_set_config ATST_NOTIFY_SPOOL "$SP/run.7.7"
  [ "$(ATST_NOTIFY_SPOOL=A bash -c '. "$1/common.sh"; printf %s "$ATST_NOTIFY_SPOOL"' _ "$repo")" = A ]
  [ "$(env -u ATST_NOTIFY_SPOOL bash -c '. "$1/common.sh"; printf %s "${ATST_NOTIFY_SPOOL+x}"' _ "$repo")" = "" ]
}

@test "NB-23: in a spool run, an empty ATST_ALERT_STATUS_FILE spools nothing keyed and the flush does not send keyed items (#110)" {
  local saved
  atst_test_source_common
  atst_spool_begin
  saved=$ATST_ALERT_STATUS_FILE

  ATST_ALERT_STATUS_FILE=""
  run atst_update_alert K23 1 '【発生】K23-first' r
  [ "$status" -eq 1 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]

  ATST_ALERT_STATUS_FILE=$saved
  atst_update_alert K23 1 '【発生】K23-second' r
  printf 'T23\n' | atst_notify_text
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 2 ]
  ATST_ALERT_STATUS_FILE=""
  run atst_spool_flush 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'ATST_ALERT_STATUS_FILE is empty'* ]]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(has_text 1 'T23')" -eq 1 ]
  [ "$(grep -c 'K23-second' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(items_in "$ATST_NOTIFY_SPOOL")" -eq 0 ]
  [ "$(status_lines '^K23,')" -eq 0 ]
  grep -q 'http=no_alert_status' "$HOME/.atst/line_error.log"
  grep -q 'K23-second' "$HOME/.atst/line_error.log"
  atst_spool_end
}

@test "NB-24: atst_spool_begin with an empty ATST_CONFIG_DIR returns 1 instead of ending the shell (#110)" {
  run bash -c '. "$1/common.sh"; ATST_CONFIG_DIR=; atst_spool_begin; echo "begin=$?"; echo "spool=${ATST_NOTIFY_SPOOL-unset}"; atst_spool_end; echo "end=$?"' _ "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *'ATST_CONFIG_DIR is empty'* ]]
  [[ "$output" == *'begin=1'* ]]
  [[ "$output" == *'spool=unset'* ]]
  [[ "$output" == *'end=0'* ]]
}
