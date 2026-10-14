#!/usr/bin/env bats
# check_all.sh (#95): runs the per-minute checks in order with the names from ATST_TARGETS, keeps going
# after a failed check, cuts off a hung one, never runs twice at a time, and reports an unset
# ATST_TARGETS, a cut-off check and a runner stuck on its lock once each (recovery once).
# The runner runs from a copy of the repository in the sandbox (atst_test_make_runner_home) whose
# checks are stubs recording their arguments (atst_test_stub_script), unless a test puts the real one
# back. Also covers the test_helper functions made for it.

load test_helper

CHECKS="check_reboot check_order check_process check_monitoring check_ping check_price check_spread heartbeat"

setup() {
  local n
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  home=$(atst_test_make_runner_home)
  atst_test_set_targets A
  atst_test_set_config ATST_CHECK_TIMEOUT 2
  atst_test_set_config ATST_ORDER_CHECK_INTERVAL 0
  for n in $CHECKS; do
    atst_test_stub_script "$home" "$n.sh" record
  done
  CALLS="$ATST_TEST_SANDBOX/calls.log"
  ST="$HOME/.atst/alert_status"
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
  [ "$(wc -l < "$CALLS")" -eq 8 ]
  [ "$(calls_of check_order.sh)" -eq 2 ]
  [ "$(calls_of check_process.sh)" -eq 1 ]
  [ "$(calls_of check_monitoring.sh)" -eq 1 ]
  [ "$(calls_of check_ping.sh)" -eq 1 ]
  [ "$(calls_of check_price.sh)" -eq 1 ]
  [ "$(calls_of check_spread.sh)" -eq 1 ]
  [ "$(calls_of heartbeat.sh)" -eq 1 ]
}

@test "RUN-07: check_order exiting 1 (#101) is not a cut-off" {
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
  [ "$(wc -l < "$CALLS")" -eq 9 ]
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

  # TIMEOUT 2 gives 8 * 2 + 865 = 881 seconds; shorter or unknown elapsed times say nothing.
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

  echo "$(( now - 1000 ))" > "$HOME/.atst/check_all.started"
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
    run bash "$home/check_all.sh"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c ATST_CHECK_TIMEOUT)" -eq 1 ] || { echo "value=$v"; false; }
    [[ "$(printf '%s\n' "$output" | grep ATST_CHECK_TIMEOUT)" == *40* ]]
  done
  atst_test_set_config ATST_CHECK_TIMEOUT 2
  run bash "$home/check_all.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c ATST_CHECK_TIMEOUT)" -eq 0 ]
}

@test "RUN-15: an invalid ATST_ORDER_CHECK_INTERVAL (51, 08) falls back to 30 with one line" {
  local v
  for v in 51 08; do
    rm -f "$CALLS"
    atst_test_set_config ATST_ORDER_CHECK_INTERVAL "$v"
    # The default 30 seconds are not waited for: cut the runner after 3 seconds.
    run timeout 3 bash "$home/check_all.sh"
    [ "$status" -eq 124 ] || { echo "value=$v status=$status"; false; }
    [ "$(printf '%s\n' "$output" | grep -c ATST_ORDER_CHECK_INTERVAL)" -eq 1 ]
    [[ "$(printf '%s\n' "$output" | grep ATST_ORDER_CHECK_INTERVAL)" == *30* ]]
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
  run grep -c eval "$repo/check_all.sh" "$repo/run_with_targets.sh" "$repo/common.sh"
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *:0 ]]
  [[ "${lines[1]}" == *:0 ]]
  [[ "${lines[2]}" == *:0 ]]
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
  [[ "$output" == *"[warn] ~/.atst/config may not have been read completely"* ]]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(status_lines '^RUNNER_TARGETS_EMPTY,1,')" -eq 1 ]
  [ "$(calls)" = "$(printf 'check_reboot.sh\nheartbeat.sh')" ]
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
