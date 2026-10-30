#!/usr/bin/env bats
# check_all.sh (#95): runs the per-minute checks in order with the names from ATST_TARGETS, keeps going
# after a failed check, cuts off a hung one, never runs twice at a time, and reports an unset
# ATST_TARGETS, a cut-off check and a runner stuck on its lock once each (recovery once).
# The runner runs from a copy of the repository in the sandbox (atst_test_make_runner_home) whose
# checks are stubs recording their arguments (atst_test_stub_script), unless a test puts the real one
# back. Also covers the test_helper functions made for it.
# LOG-xx (#144): the stderr of the runner and its checks goes to ~/.atst/log/check_all.log.
# self_heal.sh (#140) is not in CHECKS: the real one runs last and, without ~/.atst/self_heal.enabled,
# exits at once without a call or a line (RUN-31..34 cover it).

load ../test_helper

CHECKS="check_reboot check_order check_process check_monitoring check_tick check_trade_ready check_ping check_price check_spread heartbeat"

setup() {
  local n
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  home=$(atst_test_make_runner_home)
  atst_test_set_targets A
  atst_test_set_config ATST_CHECK_TIMEOUT 2
  atst_test_set_config ATST_ORDER_CHECK_INTERVAL 0
  for n in $CHECKS; do
    atst_test_stub_script "$home" "$n.sh" record
  done
  CALLS="$ATST_TEST_SANDBOX/calls.log"
  ST="$HOME/.atst/alert_status"
  D="$HOME/.atst/log"
  L="$D/check_all.log"
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
  # LOG-04a / LOG-04c / LOG-09 take permissions away; give them back so the sandbox can be removed.
  chmod -R u+rwX "$ATST_TEST_SANDBOX" 2>/dev/null
  atst_test_teardown_sandbox
}

# calls.log without the epoch column.
calls() {
  sed -E 's/ [0-9]+//' "$CALLS"
}

# Number of lines in calls.log starting with "<name> " (0 without the file).
calls_of() {
  if [ -e "$CALLS" ]; then
    grep -c "^$1 " "$CALLS"
  else
    echo 0
  fi
}

# Number of alert_status lines matching the regex $1 (0 without the file).
status_lines() {
  if [ -e "$ST" ]; then
    grep -c "$1" "$ST"
  else
    echo 0
  fi
}

unset_targets() {
  sed -i '/^ATST_TARGETS=/d' "$HOME/.atst/config"
}

# Starts a process holding the lock on $1 (as another process would) and waits until it holds it.
# The probe cannot take the lock away: the holder waits for it with a blocking flock.
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

# stub_stderr <name> <mode> <text>: atst_test_stub_script, then <text> on stderr before the mode's
# last line (for hang, before "exec sleep 300"). <text> is a fixed string of letters, digits and -.
stub_stderr() {
  atst_test_stub_script "$home" "$1" "$2" || return 1
  sed -i "\$i echo '$3' 1>&2" "$home/$1"
}

# The run log (empty without it).
runlog() {
  cat "$L" 2>/dev/null
}

# What every run that could not use the log must still do (LOG-04a/b/c, LOG-09): all checks once
# (check_order twice: 11 lines in calls.log), no push, and the check's stderr where it was (in $output), without a START line.
assert_ran_unlogged() {
  [ "$status" -eq 0 ] || return 1
  [ "$(wc -l < "$CALLS")" -eq 11 ] || return 1
  [ "$(calls_of check_order.sh)" -eq 2 ] || return 1
  [ "$(atst_test_push_count)" -eq 0 ] || return 1
  [[ "$output" == *PING-STDERR-7f3a* ]] || return 1
  [[ "$output" != *"===== START"* ]] || return 1
}

release_lock() {
  local pid
  pid=$(cat "$ATST_TEST_SANDBOX/holder.pid")
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  rm -f "$ATST_TEST_SANDBOX/holder.pid"
}

@test "RUN-01: an argument prints the usage and exits 1 without running a check or taking the lock" {
  run bash "$home/check_all.sh" x
  [ "$status" -eq 1 ]
  [[ "$output" == *Usage* ]]
  [ ! -e "$CALLS" ]
  [ ! -e "$HOME/.atst/check_all.lock" ]
}

@test "RUN-02: names with ' and double spaces and * reach every MT check as one argument each, in order" {
  local expected
  atst_test_set_targets "it's" 'a  b' '*'
  cd "$ATST_TEST_SANDBOX"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  expected="check_reboot.sh
check_order.sh [it's] [a  b] [*]
check_process.sh [it's] [a  b] [*]
check_monitoring.sh [it's] [a  b] [*]
check_tick.sh [it's] [a  b] [*]
check_trade_ready.sh [it's] [a  b] [*]
check_ping.sh [it's] [a  b] [*]
check_price.sh [it's] [a  b] [*]
check_spread.sh [it's] [a  b] [*]
check_order.sh [it's] [a  b] [*]
heartbeat.sh"
  [ "$(calls)" = "$expected" ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "RUN-03: an unset ATST_TARGETS is reported once, and its setting is reported once" {
  unset_targets
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TARGETS_EMPTY,1,')" -eq 1 ]
  [ "$(calls)" = "$(printf 'check_reboot.sh\nheartbeat.sh')" ]
  grep -qF '【発生】監視対象が設定されていません。~/.atst/config の ATST_TARGETS に MetaTrader のフォルダ名を書いてください (MetaTrader ごとの監視と約定通知、再起動時の MetaTrader の自動起動が止まっています)' "$ATST_TEST_CURL_LOG"

  run bash "$home/check_all.sh"
  [ "$(atst_test_push_count)" -eq 1 ]

  atst_test_set_targets A
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(status_lines '^RUNNER_TARGETS_EMPTY,0,')" -eq 1 ]
  grep -qF '【復帰】監視対象が設定されました' "$ATST_TEST_CURL_LOG"
  [ "$(grep -c '^check_process.sh \[A\]$' <(calls))" -eq 1 ]

  run bash "$home/check_all.sh"
  [ "$(atst_test_push_count)" -eq 2 ]
}

@test "RUN-04: (), ('') and ('a' '') are reported like an unset ATST_TARGETS" {
  local v
  for v in empty blank partial; do
    rm -f "$ST" "$ATST_TEST_CURL_LOG" "$CALLS"
    unset_targets
    case "$v" in
      empty) atst_test_set_targets ;;
      blank) atst_test_set_targets '' ;;
      partial) atst_test_set_targets a '' ;;
    esac
    run bash "$home/check_all.sh"
    [ "$status" -eq 0 ]
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "case=$v"; false; }
    [ "$(status_lines '^RUNNER_TARGETS_EMPTY,1,')" -eq 1 ]
    [ "$(calls)" = "$(printf 'check_reboot.sh\nheartbeat.sh')" ] || { echo "case=$v"; false; }
  done
}

@test "RUN-05: a sparse array ([1]=a) counts as set" {
  unset_targets
  echo 'ATST_TARGETS=([1]=a)' >> "$HOME/.atst/config"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(status_lines '^RUNNER_TARGETS_EMPTY,1,')" -eq 0 ]
  [ "$(grep -c '^check_process.sh \[a\]$' <(calls))" -eq 1 ]
}

@test "RUN-06: a failing check does not stop the others (AC5)" {
  atst_test_stub_script "$home" check_process.sh fail
  cp -p "$repo/check_reboot.sh" "$home/"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ -s "$HOME/.atst/uptime" ]
  [ "$(wc -l < "$CALLS")" -eq 10 ]
  [ "$(calls_of check_order.sh)" -eq 2 ]
  [ "$(calls_of check_process.sh)" -eq 1 ]
  [ "$(calls_of check_monitoring.sh)" -eq 1 ]
  [ "$(calls_of check_tick.sh)" -eq 1 ]
  [ "$(calls_of check_trade_ready.sh)" -eq 1 ]
  [ "$(calls_of check_ping.sh)" -eq 1 ]
  [ "$(calls_of check_price.sh)" -eq 1 ]
  [ "$(calls_of check_spread.sh)" -eq 1 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
}

# run_check treats only 124/137 as a cut-off (#95); exit 1 here stands for any other failure.
@test "RUN-07: a check exiting 1 (not 124/137) is not a cut-off: check_order still runs twice" {
  atst_test_stub_script "$home" check_order.sh exit1
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_')" -eq 0 ]
  [ "$(calls_of check_order.sh)" -eq 2 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
}

@test "RUN-08: a hung check is cut off at the timeout, reported once, and its recovery once (AC6)" {
  local t0 el
  atst_test_stub_script "$home" check_ping.sh hang
  t0=$(date +%s)
  run timeout 60 bash "$home/check_all.sh"
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 12 ]
  [ "$(calls_of check_tick.sh)" -eq 1 ]
  [ "$(calls_of check_trade_ready.sh)" -eq 1 ]
  [ "$(calls_of check_price.sh)" -eq 1 ]
  [ "$(calls_of check_spread.sh)" -eq 1 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_PING,1,')" -eq 1 ]
  grep -qF '【発生】チェックが 2 秒で終わらず打ち切りました: check_ping.sh' "$ATST_TEST_CURL_LOG"

  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]

  atst_test_stub_script "$home" check_ping.sh record
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_PING,0,')" -eq 1 ]
  grep -qF '【復帰】チェックが時間内に終わるようになりました: check_ping.sh' "$ATST_TEST_CURL_LOG"
  run pgrep -f "$home/check_ping.sh"
  [ "$status" -ne 0 ]
}

@test "RUN-09: a check ignoring TERM is killed and reported once" {
  local t0 el
  atst_test_stub_script "$home" check_ping.sh hang_ignore_term
  t0=$(date +%s)
  run timeout 60 bash "$home/check_all.sh"
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 12 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_PING,1,')" -eq 1 ]
  run pgrep -f "$home/check_ping.sh"
  [ "$status" -ne 0 ]
}

@test "RUN-10: while another process holds the lock, the runner runs nothing and keeps check_all.started" {
  mkdir -p "$HOME/.atst"
  echo "$(( $(date +%s) - 10 ))" > "$HOME/.atst/check_all.started"
  cp "$HOME/.atst/check_all.started" "$ATST_TEST_SANDBOX/started.orig"
  hold_lock "$HOME/.atst/check_all.lock"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  cmp "$HOME/.atst/check_all.started" "$ATST_TEST_SANDBOX/started.orig"
  release_lock
}

@test "RUN-11: a second runner started during the first exits at once without running a check" {
  local i t0 el pid
  atst_test_stub_script "$home" check_process.sh slow
  # The slow stub takes 3 seconds; the default cap of these tests (2) would cut it off and notify.
  atst_test_set_config ATST_CHECK_TIMEOUT 10
  bash "$home/check_all.sh" >/dev/null 2>&1 </dev/null 3>&- &
  pid=$!
  echo "$pid" > "$ATST_TEST_SANDBOX/bg.pid"
  for i in $(seq 1 50); do
    grep -q '^check_reboot.sh ' "$CALLS" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '^check_reboot.sh ' "$CALLS"

  t0=$(date +%s)
  run bash "$home/check_all.sh"
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 2 ]

  wait "$pid"
  rm -f "$ATST_TEST_SANDBOX/bg.pid"
  [ "$(wc -l < "$CALLS")" -eq 11 ]
  [ "$(calls_of check_reboot.sh)" -eq 1 ]
  [ "$(calls_of check_order.sh)" -eq 2 ]
  [ "$(calls_of check_process.sh)" -eq 1 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "RUN-12: a runner stuck on the lock past the threshold is reported once, the recovery once" {
  local now v
  mkdir -p "$HOME/.atst"
  hold_lock "$HOME/.atst/check_all.lock"
  now=$(date +%s)

  # TIMEOUT 2 gives 10 * 2 + 975 + 155 = 1150 seconds (+ 155: self_heal, #140); shorter or unknown
  # elapsed times say nothing.
  for v in "$(( now - 60 ))" "$(( now - 870 ))" abc "$(( now + 1000 ))" none; do
    if [ "$v" = none ]; then
      rm -f "$HOME/.atst/check_all.started"
    else
      echo "$v" > "$HOME/.atst/check_all.started"
    fi
    run bash "$home/check_all.sh"
    [ "$status" -eq 0 ]
  done
  [ "$(atst_test_push_count)" -eq 0 ]
  [ ! -e "$CALLS" ]

  echo "$(( now - 1200 ))" > "$HOME/.atst/check_all.started"
  for v in 1 2 3; do
    run bash "$home/check_all.sh"
    [ "$status" -eq 0 ]
  done
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_STUCK,1,')" -eq 1 ]
  grep -qF '【発生】毎分の監視 (check_all.sh) が、前回の実行が終わらないため' "$ATST_TEST_CURL_LOG"
  grep -qF '秒以上止まっています' "$ATST_TEST_CURL_LOG"
  [ ! -e "$CALLS" ]

  release_lock
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(status_lines '^RUNNER_STUCK,0,')" -eq 1 ]
  grep -qF '【復帰】毎分の監視 (check_all.sh) が再開しました' "$ATST_TEST_CURL_LOG"
}

@test "RUN-13: check_order runs twice, the second at least ATST_ORDER_CHECK_INTERVAL later (AC8)" {
  local t1 t2
  atst_test_set_config ATST_ORDER_CHECK_INTERVAL 1
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(calls_of check_order.sh)" -eq 2 ]
  t1=$(awk '/^check_order.sh /{print $2}' "$CALLS" | sed -n 1p)
  t2=$(awk '/^check_order.sh /{print $2}' "$CALLS" | sed -n 2p)
  [ "$t2" -ge "$(( t1 + 1 ))" ]
}

@test "RUN-14: an invalid ATST_CHECK_TIMEOUT (040, 0, 301, abc) falls back to 40 with one line" {
  local v
  for v in 040 0 301 abc; do
    atst_test_set_config ATST_CHECK_TIMEOUT "$v"
    rm -f "$HOME/.atst/log/check_all.log"
    run bash "$home/check_all.sh"
    [ "$status" -eq 0 ]
    [ "$(runlog | grep -c ATST_CHECK_TIMEOUT)" -eq 1 ] || { echo "value=$v"; false; }
    [[ "$(runlog | grep ATST_CHECK_TIMEOUT)" == *40* ]]
  done
  atst_test_set_config ATST_CHECK_TIMEOUT 2
  rm -f "$HOME/.atst/log/check_all.log"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -c ATST_CHECK_TIMEOUT)" -eq 0 ]
}

@test "RUN-15: an invalid ATST_ORDER_CHECK_INTERVAL (51, 08) falls back to 30 with one line" {
  local v
  for v in 51 08; do
    rm -f "$CALLS" "$HOME/.atst/log/check_all.log"
    atst_test_set_config ATST_ORDER_CHECK_INTERVAL "$v"
    # The default 30 seconds are not waited for: cut the runner after 3 seconds.
    run timeout 3 bash "$home/check_all.sh"
    [ "$status" -eq 124 ] || { echo "value=$v status=$status"; false; }
    [ "$(runlog | grep -c ATST_ORDER_CHECK_INTERVAL)" -eq 1 ]
    [[ "$(runlog | grep ATST_ORDER_CHECK_INTERVAL)" == *30* ]]
    [ "$(calls_of check_order.sh)" -eq 1 ]
  done
}

@test "RUN-16: checks do not inherit the runner's lock fd" {
  cat > "$home/check_process.sh" <<EOF
#!/bin/bash
readlink /proc/self/fd/7 2>/dev/null >> "$ATST_TEST_SANDBOX/fd7.log"
echo end >> "$ATST_TEST_SANDBOX/fd7.log"
EOF
  chmod 755 "$home/check_process.sh"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'check_all.lock' "$ATST_TEST_SANDBOX/fd7.log")" -eq 0 ]
  [ "$(grep -c end "$ATST_TEST_SANDBOX/fd7.log")" -eq 1 ]
}

@test "RUN-17: a name matching no MetaTrader is reported once as TARGET_<NAME> through the runner (AC9)" {
  cp -p "$repo/check_process.sh" "$home/"
  atst_test_set_targets NOSUCH
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^TARGET_NOSUCH,1,')" -eq 1 ]
  grep -qF '監視対象のMetaTraderが見つかりません' "$ATST_TEST_CURL_LOG"
  grep -qF '~/.atst/config の ATST_TARGETS' "$ATST_TEST_CURL_LOG"
}

@test "RUN-18: stale monitoring data is reported once through the runner (AC9)" {
  cp -p "$repo/check_monitoring.sh" "$home/"
  atst_test_make_mt A_MT4 MT4
  atst_test_make_monitoring_csv A_MT4 500 150.0 10 0.01
  atst_test_set_targets A_MT4
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^MONITORING_')" -eq 1 ]
}

@test "RUN-19: no eval in check_all.sh, run_with_targets.sh and common.sh (AC3)" {
  run grep -c eval "$repo/check_all.sh" "$repo/run_with_targets.sh" "$repo/common.sh" \
    "$repo/lib/atst_config.sh" "$repo/lib/atst_line.sh" "$repo/lib/atst_mt.sh"
  [ "${#lines[@]}" -eq 6 ]
  [[ "${lines[0]}" == *:0 ]]
  [[ "${lines[1]}" == *:0 ]]
  [[ "${lines[2]}" == *:0 ]]
  [[ "${lines[3]}" == *:0 ]]
  [[ "${lines[4]}" == *:0 ]]
  [[ "${lines[5]}" == *:0 ]]
}

@test "RUN-20: an unclosed ATST_TARGETS in the template config still reaches LINE as RUNNER_TARGETS_EMPTY" {
  local conf="$HOME/.atst/config"
  # The template as a user would have it, with the ATST_TARGETS line (at the end) mistyped.
  cp "$repo/templates/config" "$conf"
  sed -i "s/^ATST_TARGETS=('Land Prime')\$/ATST_TARGETS=('A_MT4)/" "$conf"
  [ "$(grep -c "^ATST_TARGETS=('A_MT4)\$" "$conf")" -eq 1 ]
  # Everything the notification needs comes before it.
  [ "$(grep -n '^ATST_LINE_ID=' "$conf" | cut -d: -f1)" -lt "$(grep -n '^ATST_TARGETS=' "$conf" | cut -d: -f1)" ]
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  runlog | grep -qF '[warn] ~/.atst/config may not have been read completely'
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TARGETS_EMPTY,1,')" -eq 1 ]
  [ "$(calls)" = "$(printf 'check_reboot.sh\nheartbeat.sh')" ]
}

@test "LOG-01: a check's stderr goes to the log (700/600), not to the terminal; stdout and the run are unchanged (AC-3)" {
  local m0 ref
  stub_stderr check_ping.sh record PING-STDERR-7f3a
  sed -i '$i echo PING-STDOUT-2b8e' "$home/check_ping.sh"
  m0=$(stat -c %a "$HOME/.atst")
  run bash -c 'umask 022; exec bash "$1"' _ "$home/check_all.sh"
  ( umask 022; : > "$ATST_TEST_SANDBOX/umask.ref" )
  ref=$(stat -c %a "$ATST_TEST_SANDBOX/umask.ref")
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -c PING-STDERR-7f3a)" -eq 1 ]
  [[ "$output" != *PING-STDERR-7f3a* ]]
  [[ "$output" == *PING-STDOUT-2b8e* ]]
  [ "$(runlog | grep -c PING-STDOUT-2b8e)" -eq 0 ]
  [[ "$output" != *"===== START"* ]]
  [ "$(stat -c %a "$D")" = 700 ]
  [ "$(stat -c %a "$L")" = 600 ]
  [ "$(stat -c %a "$HOME/.atst")" = "$m0" ]
  [ "$(stat -c %a "$HOME/.atst/check_all.started")" = "$ref" ]
  [ "$(stat -c %a "$HOME/.atst/check_all.lock")" = "$ref" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(wc -l < "$CALLS")" -eq 11 ]
  [ "$(calls_of check_order.sh)" -eq 2 ]
  [ "$(calls_of check_reboot.sh)" -eq 1 ]
  [ "$(calls_of check_process.sh)" -eq 1 ]
  [ "$(calls_of check_monitoring.sh)" -eq 1 ]
  [ "$(calls_of check_tick.sh)" -eq 1 ]
  [ "$(calls_of check_trade_ready.sh)" -eq 1 ]
  [ "$(calls_of check_ping.sh)" -eq 1 ]
  [ "$(calls_of check_price.sh)" -eq 1 ]
  [ "$(calls_of check_spread.sh)" -eq 1 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
}

@test "LOG-02: each run starts with one START line in a fixed format, before its checks' lines (AC-4)" {
  local s2 p2
  stub_stderr check_ping.sh record PING-STDERR-7f3a
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -c '^===== START ')" -eq 2 ]
  [ "$(runlog | grep -cE '^===== START [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} pid=[0-9]+ =====$')" -eq 2 ]
  s2=$(runlog | awk '/^===== START /{n++; if (n==2) print NR}')
  p2=$(runlog | awk '/PING-STDERR-7f3a/{n++; if (n==2) print NR}')
  [ -n "$s2" ] && [ -n "$p2" ]
  [ "$s2" -lt "$p2" ]
  [ "$(runlog | head -n 1 | grep -c '^===== START ')" -eq 1 ]
}

@test "LOG-03: the [warn] of common.sh on a broken config is kept in the log (AC-5)" {
  local conf="$HOME/.atst/config" s w
  cp "$repo/templates/config" "$conf"
  sed -i "s/^ATST_TARGETS=('Land Prime')\$/ATST_TARGETS=('A_MT4)/" "$conf"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -cF '[warn] ~/.atst/config may not have been read completely')" -eq 1 ]
  s=$(runlog | grep -n '^===== START ' | head -n 1 | cut -d: -f1)
  w=$(runlog | grep -nF '[warn] ~/.atst/config may not have been read completely' | cut -d: -f1)
  [ "$s" -lt "$w" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TARGETS_EMPTY,1,')" -eq 1 ]
}

@test "LOG-04a: a log directory without write permission: nothing is logged and the run is unchanged (AC-6)" {
  [ "$EUID" -ne 0 ] || skip "root ignores permissions"
  stub_stderr check_ping.sh record PING-STDERR-7f3a
  mkdir -p "$D"
  chmod 500 "$D"
  run bash "$home/check_all.sh"
  assert_ran_unlogged
  [ ! -e "$L" ]
  [ "$(stat -c %a "$D")" = 500 ]
}

@test "LOG-04b: ~/.atst/log as a plain file: nothing is logged and the run is unchanged (AC-6)" {
  stub_stderr check_ping.sh record PING-STDERR-7f3a
  printf 'keep-7d21\n' > "$D"
  cp "$D" "$ATST_TEST_SANDBOX/d.orig"
  run bash "$home/check_all.sh"
  assert_ran_unlogged
  [ -f "$D" ]
  cmp "$D" "$ATST_TEST_SANDBOX/d.orig"
}

@test "LOG-04c: a read-only log: left as it is and the run is unchanged (AC-6)" {
  local s0
  [ "$EUID" -ne 0 ] || skip "root ignores permissions"
  stub_stderr check_ping.sh record PING-STDERR-7f3a
  mkdir -p "$D"
  printf 'old-3c90\n' > "$L"
  chmod 400 "$L"
  s0=$(stat -c %s "$L")
  run bash "$home/check_all.sh"
  assert_ran_unlogged
  [ "$(stat -c %s "$L")" -eq "$s0" ]
  [ "$(stat -c %a "$L")" = 400 ]
}

@test "LOG-05: a cut-off check keeps what it printed and gets 'exit 124' (AC-7)" {
  local t0 el h e
  stub_stderr check_ping.sh hang PING-BEFORE-HANG
  t0=$(date +%s)
  run timeout 60 bash "$home/check_all.sh"
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 12 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_PING,1,')" -eq 1 ]
  [ "$(runlog | grep -c PING-BEFORE-HANG)" -eq 1 ]
  [ "$(runlog | grep -cx 'check_ping.sh: exit 124')" -eq 1 ]
  h=$(runlog | grep -n PING-BEFORE-HANG | cut -d: -f1)
  e=$(runlog | grep -nx 'check_ping.sh: exit 124' | cut -d: -f1)
  [ "$h" -lt "$e" ]
}

@test "LOG-06: a failing check gets '<name>.sh: exit <rc>' without LINE; exit 0 gets no line (AC-7)" {
  atst_test_stub_script "$home" check_ping.sh fail
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -cx 'check_ping.sh: exit 3')" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_')" -eq 0 ]

  atst_test_stub_script "$home" check_ping.sh record
  rm -f "$L"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -c ': exit ')" -eq 0 ]
  [ "$(runlog | grep -c '^===== START ')" -eq 1 ]
}

@test "LOG-07: a run skipped on the lock says so in one line, with the age of the run holding it or ? (AC-8)" {
  local s k
  echo "$(( $(date +%s) - 10 ))" > "$HOME/.atst/check_all.started"
  hold_lock "$HOME/.atst/check_all.lock"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -c 'another run holds the lock')" -eq 1 ]
  [ "$(runlog | grep -cE '^another run holds the lock \(started -?[0-9]+ s ago\); skipped$')" -eq 1 ]
  [ "$(runlog | grep -c '^===== START ')" -eq 1 ]
  s=$(runlog | grep -n '^===== START ' | cut -d: -f1)
  k=$(runlog | grep -n 'another run holds the lock' | cut -d: -f1)
  [ "$s" -lt "$k" ]
  [ ! -e "$CALLS" ]
  [ "$(atst_test_push_count)" -eq 0 ]

  rm -f "$HOME/.atst/check_all.started" "$L"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -cxF 'another run holds the lock (started ? s ago); skipped')" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 0 ]

  # An elapsed inherited from the environment is not used.
  rm -f "$L"
  run env elapsed=999 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -cxF 'another run holds the lock (started ? s ago); skipped')" -eq 1 ]
  [ "$(runlog | grep -c 'started 999 s')" -eq 0 ]
  [ ! -e "$CALLS" ]
  release_lock
}

@test "LOG-08: no secret reaches the log when a cut-off notice fails to send (AC-11)" {
  printf 'abcdefghijkl1234\n' > "$HOME/.atst/.line_token"
  printf 'U0123456789abcdef\n' > "$HOME/.atst/.line_id"
  chmod 600 "$HOME/.atst/.line_token" "$HOME/.atst/.line_id"
  export ATST_TEST_CURL_HTTP_CODE=500
  stub_stderr check_ping.sh hang PING-BEFORE-HANG
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ -s "$L" ]
  [ "$(runlog | grep -cE 'abcdefghijkl1234|U0123456789abcdef|cdef|Authorization')" -eq 0 ]
  [ "$(runlog | grep -cx 'check_ping.sh: exit 124')" -eq 1 ]
}

@test "LOG-09: in POSIX mode a log that cannot be opened still does not stop the run" {
  local s0
  [ "$EUID" -ne 0 ] || skip "root ignores permissions"
  stub_stderr check_ping.sh record PING-STDERR-7f3a
  mkdir -p "$D"
  printf 'old-3c90\n' > "$L"
  chmod 400 "$L"
  s0=$(stat -c %s "$L")
  run env POSIXLY_CORRECT=1 bash "$home/check_all.sh"
  assert_ran_unlogged
  [ "$(stat -c %s "$L")" -eq "$s0" ]
}

@test "LOG-10: an existing log directory and file keep their modes and contents" {
  mkdir -p "$D"
  chmod 750 "$D"
  printf 'prev-run-6e14\n' > "$L"
  chmod 640 "$L"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$D")" = 750 ]
  [ "$(stat -c %a "$L")" = 640 ]
  [ "$(runlog | head -n 1)" = prev-run-6e14 ]
  [ "$(runlog | grep -c '^===== START ')" -eq 1 ]
}

@test "LOG-11: in POSIX mode the redirection holds for the whole run" {
  stub_stderr check_ping.sh record PING-STDERR-7f3a
  run env POSIXLY_CORRECT=1 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -c PING-STDERR-7f3a)" -eq 1 ]
  [[ "$output" != *PING-STDERR-7f3a* ]]
  [ "$(runlog | grep -c '^===== START ')" -eq 1 ]
  [ "$(wc -l < "$CALLS")" -eq 11 ]
}

@test "LOG-12: an argument exits before the log is touched" {
  run bash "$home/check_all.sh" x
  [ "$status" -eq 1 ]
  [[ "$output" == *Usage* ]]
  [ ! -e "$D" ]
}

@test "LOG-13: without ~/.atst, it is made 700 together with the log" {
  rm -rf "$HOME/.atst"
  # The template config waits 30 seconds for the second check_order: cut the runner after 5 seconds.
  run timeout 5 bash -c 'umask 022; exec bash "$1"' _ "$home/check_all.sh"
  [ "$status" -eq 124 ]
  [ "$(stat -c %a "$HOME/.atst")" = 700 ]
  [ "$(stat -c %a "$D")" = 700 ]
  [ "$(stat -c %a "$L")" = 600 ]
  [ "$(runlog | grep -c '^===== START ')" -eq 1 ]
  [ -s "$HOME/.atst/config" ]
}

@test "LOG-14: a check killed after ignoring TERM gets 'exit 137'" {
  atst_test_stub_script "$home" check_ping.sh hang_ignore_term
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -cx 'check_ping.sh: exit 137')" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "LOG-15: the redirection works in a cron-like minimal environment (env -i)" {
  stub_stderr check_ping.sh record PING-STDERR-7f3a
  run env -i HOME="$HOME" PATH="$PATH" ATST_TEST_SANDBOX="$ATST_TEST_SANDBOX" \
    ATST_TEST_CURL_LOG="$ATST_TEST_CURL_LOG" bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(runlog | grep -c PING-STDERR-7f3a)" -eq 1 ]
  [[ "$output" != *PING-STDERR-7f3a* ]]
  [ "$(runlog | grep -c '^===== START ')" -eq 1 ]
  [ "$(wc -l < "$CALLS")" -eq 11 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

# RUN-21 to RUN-24 (#136): the real heartbeat.sh at the end of the run (the other checks stay stubs, so the
# curl log holds the heartbeat only). ping while healthy, /fail while an allow-listed key is 1.
HB_U=https://example.invalid/ping/abcd9876

# use_real_heartbeat: put the real heartbeat.sh back into the runner home and set the dummy URL.
use_real_heartbeat() {
  cp -p "$repo/heartbeat.sh" "$home/" || return 1
  atst_test_set_config ATST_HEARTBEAT_URL "$HB_U"
  unset ATST_TEST_CURL_BODY ATST_TEST_CURL_HTTP_CODE ATST_TEST_CURL_HTTP_CODE_SEQ ATST_TEST_CURL_EXIT
}

hb_fail_lines() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep -c 'abcd9876/fail"' "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

hb_ping_lines() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep abcd9876 "$ATST_TEST_CURL_LOG" | grep -vc '/fail'
  else
    echo 0
  fi
}

@test "RUN-21/HB-30: all checks healthy: the real heartbeat sends one ping, no /fail, no cut-off (AC6, AC11)" {
  use_real_heartbeat
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(hb_ping_lines)" -eq 1 ]
  [ "$(hb_fail_lines)" -eq 0 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_HEARTBEAT,1,')" -eq 0 ]
  [ "$(calls_of heartbeat.sh)" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "RUN-22/HB-31: PROCESS_A set to 1: one /fail with PROCESS_A and no ping (AC7)" {
  use_real_heartbeat
  printf 'PROCESS_A,1,%s\n' "$(date +%s)" > "$ST"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(hb_fail_lines)" -eq 1 ]
  [ "$(hb_ping_lines)" -eq 0 ]
  [ "$(sed -nE 's/.*data(-raw)? = "([^"]*)".*/\2/p' "$ATST_TEST_CURL_LOG")" = PROCESS_A ]
}

@test "RUN-23/HB-32: only PRICE_A set to 1: a ping, no /fail (AC6)" {
  use_real_heartbeat
  printf 'PRICE_A,1,%s\n' "$(date +%s)" > "$ST"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(hb_ping_lines)" -eq 1 ]
  [ "$(hb_fail_lines)" -eq 0 ]
}

@test "RUN-24/HB-33: a failing heartbeat curl: the run exits 0, one line without the URL in the log (AC11, AC21)" {
  use_real_heartbeat
  export ATST_TEST_CURL_EXIT=6
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  # the stderr of the run goes to ~/.atst/log/check_all.log (#144), not to $output
  [ "$(runlog | grep -c '^heartbeat: send failed (curl exit 6)$')" -eq 1 ]
  [[ "$output" != *example.invalid* ]]
  [ "$(status_lines '^RUNNER_TIMEOUT_HEARTBEAT,1,')" -eq 0 ]
  [ -z "$(grep -rl example.invalid "$HOME/.atst" | grep -vE '/(config|\.heartbeat_url)$')" ]
}

@test "TH-01: atst_test_set_targets writes an array read back element by element, only in the sandbox" {
  local sum rc=0
  atst_test_set_targets "it's" 'a  b' '*'
  run bash -c '. "$HOME/.atst/config"; printf "%s\n" "${#ATST_TARGETS[@]}" "${ATST_TARGETS[@]}"'
  [ "$status" -eq 0 ]
  # $output, not ${lines[@]}: bats 1.1.0 builds lines with an unquoted expansion, which expands *.
  [ "$output" = "$(printf '%s\n' 3 "it's" 'a  b' '*')" ]
  sum=$(cksum < "$HOME/.atst/config")
  ( HOME="$ATST_TEST_SANDBOX/other"; atst_test_set_targets z ) || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(cksum < "$HOME/.atst/config")" = "$sum" ]
}

@test "TH-02: atst_test_make_runner_home copies the scripts into the sandbox keeping exec bits" {
  run atst_test_make_runner_home
  [ "$status" -eq 0 ]
  [[ "$output" == "$ATST_TEST_SANDBOX/"* ]]
  [ -x "$output/check_all.sh" ]
  [ -f "$output/common.sh" ]
  [ -f "$output/lib/atst_config.sh" ]
  [ -f "$output/templates/crontab.txt" ]
}

@test "TH-03: atst_test_stub_script records its arguments and refuses bad modes, names and dirs" {
  local d="$ATST_TEST_SANDBOX/st" out rc
  mkdir "$d"
  atst_test_stub_script "$d" x.sh record
  run bash "$d/x.sh" a 'b c'
  [ "$status" -eq 0 ]
  [[ "$(cat "$CALLS")" =~ ^x\.sh\ [0-9]+\ \[a\]\ \[b\ c\]$ ]]
  atst_test_stub_script "$d" f.sh fail
  run bash "$d/f.sh"
  [ "$status" -eq 3 ]
  atst_test_stub_script "$d" e.sh exit1
  run bash "$d/e.sh"
  [ "$status" -eq 1 ]

  rc=0; atst_test_stub_script "$d" b.sh bogus || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -e "$d/b.sh" ]
  rc=0; atst_test_stub_script "$d" ../x record || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -e "$ATST_TEST_SANDBOX/x" ]
  out=$(mktemp -d "$BATS_TMPDIR/atst-out.XXXXXX")
  rc=0; atst_test_stub_script "$out" o.sh record || rc=$?
  rmdir "$out"
  [ "$rc" -eq 1 ]
}

@test "RUN-25: a hung check_tick is cut off as RUNNER_TIMEOUT_CHECK_TICK, the later checks still run (#137)" {
  local t0 el
  atst_test_stub_script "$home" check_tick.sh hang
  t0=$(date +%s)
  run timeout 60 bash "$home/check_all.sh"
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 12 ]
  [ "$(calls_of check_ping.sh)" -eq 1 ]
  [ "$(calls_of check_price.sh)" -eq 1 ]
  [ "$(calls_of check_spread.sh)" -eq 1 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_TICK,1,')" -eq 1 ]
  grep -qF '【発生】チェックが 2 秒で終わらず打ち切りました: check_tick.sh' "$ATST_TEST_CURL_LOG"

  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]

  atst_test_stub_script "$home" check_tick.sh record
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_TICK,0,')" -eq 1 ]
  grep -qF '【復帰】チェックが時間内に終わるようになりました: check_tick.sh' "$ATST_TEST_CURL_LOG"
  run pgrep -f "$home/check_tick.sh"
  [ "$status" -ne 0 ]
}

@test "RUN-26: a missing check_tick.sh is one exit 127 line in the log, not a cut-off (#137)" {
  rm "$home/check_tick.sh"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_')" -eq 0 ]
  [ "$(runlog | grep -c 'check_tick.sh: exit 127')" -eq 1 ]
  [ "$(calls_of check_ping.sh)" -eq 1 ]
}

@test "RUN-27: stopped ticks are reported once through the runner with the real check_tick.sh (#137)" {
  local n
  cp -p "$repo/check_tick.sh" "$home/"
  atst_test_make_mt A_MT4 MT4
  # Every 60 s (no gap of ATST_MONITORING_THRESHOLD in the window), field 2 unchanged.
  for n in 720 660 600 540 480 420 360 300 240 180 120 60 0; do
    atst_test_make_monitoring_csv A_MT4 "$n" 150.0 10 0.01 12 100
  done
  atst_test_set_targets A_MT4
  # Judged on any day the test runs (the weekend gate is covered by tests/check_tick.bats).
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^TICK_A_MT4,1,')" -eq 1 ]
  grep -qF '価格データ（ティック）が 10 分以上' "$ATST_TEST_CURL_LOG"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "RUN-28: a hung check_trade_ready is cut off as RUNNER_TIMEOUT_CHECK_TRADE_READY, the later checks still run (#158)" {
  local t0 el
  atst_test_stub_script "$home" check_trade_ready.sh hang
  t0=$(date +%s)
  run timeout 60 bash "$home/check_all.sh"
  el=$(( $(date +%s) - t0 ))
  [ "$status" -eq 0 ]
  [ "$el" -le 12 ]
  [ "$(calls_of check_ping.sh)" -eq 1 ]
  [ "$(calls_of check_price.sh)" -eq 1 ]
  [ "$(calls_of check_spread.sh)" -eq 1 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_TRADE_READY,1,')" -eq 1 ]
  grep -qF '【発生】チェックが 2 秒で終わらず打ち切りました: check_trade_ready.sh' "$ATST_TEST_CURL_LOG"

  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]

  atst_test_stub_script "$home" check_trade_ready.sh record
  run timeout 60 bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_CHECK_TRADE_READY,0,')" -eq 1 ]
  grep -qF '【復帰】チェックが時間内に終わるようになりました: check_trade_ready.sh' "$ATST_TEST_CURL_LOG"
}

@test "RUN-29: the real check_trade_ready.sh through the runner: an old EA does nothing, the button OFF is reported once (#158)" {
  local n
  cp -p "$repo/check_trade_ready.sh" "$home/"
  atst_test_make_mt A_MT4 MT4
  atst_test_set_targets A_MT4
  # Judged on any day the test runs (the weekend gate is covered by tests/check_trade_ready.bats).
  atst_test_set_config ATST_TRADE_READY_WEEKEND_SKIP 0
  # (a) 8-field lines of an old EA only
  for n in 720 660 600 540 480 420 360 300 240 180 120 60 0; do
    atst_test_make_monitoring_csv A_MT4 "$n" 150.0 10 0.01 12 100
  done
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(status_lines '^TRADE_')" -eq 0 ]
  [ "$(runlog | grep -c 'check_trade_ready')" -eq 0 ]
  # (b) 14-field lines with field 10 = 0 every 60 s
  rm -f "$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
  for n in 720 660 600 540 480 420 360 300 240 180 120 60 0; do
    atst_test_make_monitoring_csv A_MT4 "$n" 150.0 10 0.01 12 100 '1,0,1,1,0,0.00'
  done
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^TRADE_A_MT4,1,')" -eq 1 ]
  grep -qF '端末の自動売買ボタンが OFF です' "$ATST_TEST_CURL_LOG"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "RUN-30: a missing check_trade_ready.sh is one exit 127 line in the log, not a cut-off (#158)" {
  rm "$home/check_trade_ready.sh"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_')" -eq 0 ]
  [ "$(runlog | grep -c 'check_trade_ready.sh: exit 127')" -eq 1 ]
  [ "$(calls_of check_ping.sh)" -eq 1 ]
}

@test "RUN-31: self_heal runs last with the names, after the heartbeat; not without targets (#140 AC14)" {
  atst_test_stub_script "$home" self_heal.sh record
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CALLS")" -eq 12 ]
  [ "$(calls | tail -2)" = "heartbeat.sh
self_heal.sh [A]" ]

  rm -f "$CALLS"
  unset_targets
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(calls_of self_heal.sh)" -eq 0 ]
}

@test "RUN-32: the real self_heal.sh without self_heal.enabled calls no mtctl.sh, even with PROCESS_A at 1 (#140 AC5)" {
  atst_test_stub_script "$home" mtctl.sh record
  mkdir -p "$HOME/.atst"
  echo "PROCESS_A,1,$(date +%s)" > "$ST"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(calls_of mtctl.sh)" -eq 0 ]
  [ ! -e "$HOME/.atst/self_heal.log" ]
  [ "$(wc -l < "$CALLS")" -eq 11 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "RUN-33: a hung self_heal is cut off as RUNNER_TIMEOUT_SELF_HEAL after every other check ran (#140 AC14)" {
  atst_test_stub_script "$home" self_heal.sh hang
  sed -i 's/^self_heal_cap=150$/self_heal_cap=2/' "$home/check_all.sh"
  [ "$(grep -c '^self_heal_cap=2$' "$home/check_all.sh")" -eq 1 ]
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(status_lines '^RUNNER_TIMEOUT_SELF_HEAL,1,')" -eq 1 ]
  [ "$(wc -l < "$CALLS")" -eq 12 ]
  [ "$(calls_of check_order.sh)" -eq 2 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '【発生】チェックが 2 秒で終わらず打ち切りました: self_heal.sh' "$ATST_TEST_CURL_LOG"
}

@test "RUN-34: enabled, MetaTrader stopped: one run sends the 【発生】 first and the 【自己修復】 after it (#140 AC14)" {
  local first second
  atst_test_make_mt A_MT4 MT4
  cp "$repo/check_process.sh" "$home/"
  atst_test_stub_script "$home" mtctl.sh record
  mkdir -p "$HOME/.atst"
  touch "$HOME/.atst/self_heal.enabled"
  chmod 600 "$HOME/.atst/self_heal.enabled"
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  first=$(grep -n '【発生】MetaTraderプロセスが動作していません' "$ATST_TEST_CURL_LOG" | cut -d: -f1)
  second=$(grep -n '【自己修復】A_MT4' "$ATST_TEST_CURL_LOG" | cut -d: -f1)
  [ -n "$first" ]
  [ -n "$second" ]
  [ "$first" -lt "$second" ]
  [ "$(grep -c '^mtctl.sh [0-9]* \[-q\] \[start\] \[A\]$' "$CALLS")" -eq 1 ]
  [ "$(wc -l < "$HOME/.atst/self_heal.log")" -eq 2 ]
  grep -q '^PROCESS_A_MT4,1,' "$ST"
}
