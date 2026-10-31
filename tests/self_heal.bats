#!/usr/bin/env bats
# self_heal.sh (#140): the opt-in self-heal run by check_all.sh. Off without ~/.atst/self_heal.enabled
# (600, ours); PROCESS_ -> mtctl.sh start, MONITORING_ (5 gates) -> mtctl.sh restart; one MetaTrader per
# run; cooldown 1800 s, 3 tries in 86400 s then one 【自己修復停止】; the MT lock, the start stamp and
# the uptime as grace gates; ~/.atst/self_heal.log as the only state. mtctl.sh is a record stub in a
# runner home (calls.log), ps a stub giving $SH_ETIMES, processes are fake /proc entries.
# Also the static checks of #140 on check_all.sh and docs/CODING_GUIDELINES.md (SH-16, SH-23, SH-24).

load test_helper

setup() {
  local real_ps
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  home=$(atst_test_make_runner_home)
  atst_test_stub_script "$home" mtctl.sh record
  atst_test_make_mt A_MT4 MT4
  atst_test_set_config ATST_MONITORING_THRESHOLD 180
  real_ps=$(command -v ps)
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  printf '#!/bin/bash\ncase " $* " in *etimes=*) echo "${SH_ETIMES:-}"; exit 0 ;; esac\nexec %q "$@"\n' "$real_ps" \
    > "$ATST_TEST_SANDBOX/bin/ps"
  chmod 755 "$ATST_TEST_SANDBOX/bin/ps"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  SH_ETIMES=400
  export PATH SH_ETIMES
  ST="$HOME/.atst/alert_status"
  SL="$HOME/.atst/self_heal.log"
  EN="$HOME/.atst/self_heal.enabled"
  E="$ATST_TEST_SANDBOX/err"
  CALLS="$ATST_TEST_SANDBOX/calls.log"
  LK="$HOME/.atst/mtctl_a_mt4.lock"
  now=$(date +%s)
}

teardown() {
  local pid
  pid=$(cat "$ATST_TEST_SANDBOX/holder.pid" 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) kill "$pid" 2>/dev/null ;;
  esac
  chmod -R u+rwX "$ATST_TEST_SANDBOX" 2>/dev/null
  atst_test_teardown_sandbox
}

own_env() {
  printf 'HOME=%s\nWINEPREFIX=%s' "$HOME" "$WINEPREFIX"
}

win_term() {
  printf 'C:\\Program Files\\%s\\terminal.exe' "$1"
}

enable() {
  touch "$EN"
  chmod 600 "$EN"
}

set_st() {
  printf '%s\n' "$@" > "$ST"
}

# The precondition P: enabled, PROCESS_A_MT4 delivered, no process.
pre_p() {
  enable
  set_st "PROCESS_A_MT4,1,$(( now - 60 ))"
}

# The precondition M: enabled, auto attach on, MONITORING_A_MT4 delivered 200 s ago, a process up 400 s.
pre_m() {
  enable
  atst_test_set_config ATST_AUTO_ATTACH_EA 1
  set_st "MONITORING_A_MT4,1,$(( now - 200 ))"
  atst_test_make_proc 123 - "$(own_env)" "$(win_term A_MT4)"
  SH_ETIMES=400
}

# run_sh [<names>...]: self_heal.sh of the runner home (default A_MT4); stdout in $output, stderr in $E.
run_sh() {
  [ "$#" -gt 0 ] || set -- A_MT4
  run bash -c 'f=$1; shift; bash "$@" 2>"$f"' _ "$E" "$home/self_heal.sh" "$@"
}

calls() {
  sed -E 's/ [0-9]+//' "$CALLS" 2>/dev/null
}

mt_calls() {
  if [ -e "$CALLS" ]; then
    grep -c '^mtctl.sh ' "$CALLS"
  else
    echo 0
  fi
}

err_lines() {
  if [ -e "$E" ]; then
    wc -l < "$E"
  else
    echo 0
  fi
}

sl_lines() {
  if [ -e "$SL" ]; then
    wc -l < "$SL"
  else
    echo 0
  fi
}

# The curl log lines of the pushes (the texts).
pushes() {
  grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" 2>/dev/null
}

hold_lock() {
  local i
  mkdir -p "$(dirname "$1")" || return 1
  ( exec 8>>"$1"; flock 8; exec sleep 30 ) >/dev/null 2>&1 </dev/null 3>&- &
  echo "$!" > "$ATST_TEST_SANDBOX/holder.pid"
  for i in $(seq 1 20); do
    flock -n "$1" true || return 0
    sleep 0.1
  done
  return 1
}

# Nothing was done: no mtctl.sh, no new self_heal.log line (than $1, default 0).
not_called() {
  [ "$(mt_calls)" -eq 0 ] || return 1
  [ "$(sl_lines)" -eq "${1:-0}" ] || return 1
}

@test "SH-01: without self_heal.enabled nothing is read, written, called or sent (AC5)" {
  set_st "PROCESS_A_MT4,1,$(( now - 60 ))"
  cp "$ST" "$ATST_TEST_SANDBOX/st.before"
  run_sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$E" ]
  [ ! -e "$CALLS" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ ! -e "$SL" ]
  [ -z "$(ls "$HOME"/.atst/mtctl_*.lock 2>/dev/null)" ]
  cmp -s "$ST" "$ATST_TEST_SANDBOX/st.before"
}

@test "SH-02: self_heal.enabled of mode 644 is OFF with one line naming it and the mode (AC6)" {
  pre_p
  chmod 644 "$EN"
  run_sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CALLS" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ ! -e "$SL" ]
  [ "$(err_lines)" -eq 1 ]
  grep -q 'self_heal.enabled' "$E"
  grep -q '644' "$E"
}

@test "SH-03: self_heal.enabled as a symlink (to a 600 file) is OFF with one line (AC6)" {
  pre_p
  rm -f "$EN"
  touch "$ATST_TEST_SANDBOX/real_enabled"
  chmod 600 "$ATST_TEST_SANDBOX/real_enabled"
  ln -s "$ATST_TEST_SANDBOX/real_enabled" "$EN"
  run_sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CALLS" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ ! -e "$SL" ]
  [ "$(err_lines)" -eq 1 ]
  grep -q 'self_heal.enabled is a symlink' "$E"
}

@test "SH-04: a 600 self_heal.enabled of ours says nothing about it (AC6)" {
  pre_p
  run_sh
  [ "$status" -eq 0 ]
  [ "$(grep -c 'self_heal.enabled' "$E")" -eq 0 ]
}

@test "SH-05: PROCESS_ delivered and no process: one mtctl.sh -q start, one 【自己修復】, begin/ok in a 600 log (AC7)" {
  pre_p
  sed -i '$i echo STUB-OUT' "$home/mtctl.sh"
  cp "$ST" "$ATST_TEST_SANDBOX/st.before"
  run_sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(calls)" = "mtctl.sh [-q] [start] [A_MT4]" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  pushes | grep -q '【自己修復】A_MT4: MT プロセス停止のため MetaTrader を起動しました (直近 24 時間で 1/3 回目)'
  [ "$(sl_lines)" -eq 2 ]
  sed -n 1p "$SL" | grep -qE '^[0-9]+,A_MT4,PROCESS_A_MT4,start,begin$'
  sed -n 2p "$SL" | grep -qE '^[0-9]+,A_MT4,PROCESS_A_MT4,start,ok$'
  [ "$(sed -n 1p "$SL" | cut -d, -f1)" -le "$(sed -n 2p "$SL" | cut -d, -f1)" ]
  [ "$(stat -c %a "$SL")" = 600 ]
  cmp -s "$ST" "$ATST_TEST_SANDBOX/st.before"
  [ "$(grep -c 'SELF_HEAL_' "$ST")" -eq 0 ]
}

@test "SH-06: PROCESS_ 0 or no line: nothing (AC7)" {
  local v
  enable
  for v in zero none; do
    rm -f "$SL" "$CALLS"
    if [ "$v" = zero ]; then
      set_st "PROCESS_A_MT4,0,$now"
    else
      set_st "PRICE_A_MT4,1,$now"
    fi
    run_sh
    [ "$status" -eq 0 ]
    not_called
    [ ! -e "$SL" ]
  done
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "SH-07: MONITORING_ with all 5 gates open: one mtctl.sh -q restart and one 【自己修復】 (AC8)" {
  pre_m
  run_sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(calls)" = "mtctl.sh [-q] [restart] [A_MT4]" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  pushes | grep -q '【自己修復】A_MT4: 監視データ停止のため MetaTrader を再起動しました (直近 24 時間で 1/3 回目)'
  sed -n 1p "$SL" | grep -qE '^[0-9]+,A_MT4,MONITORING_A_MT4,restart,begin$'
  sed -n 2p "$SL" | grep -qE '^[0-9]+,A_MT4,MONITORING_A_MT4,restart,ok$'
}

@test "SH-08a..e: each MONITORING_ gate closed alone: nothing, one reason line (AC8)" {
  local g
  for g in a b c d e; do
    rm -rf "$ATST_PROC_ROOT"/* "$SL" "$CALLS" "$E"
    sed -i '/^ATST_AUTO_ATTACH_EA=/d' "$HOME/.atst/config"
    pre_m
    case $g in
      a) set_st "MONITORING_A_MT4,1,$(( now - 100 ))" ;;
      b) rm -rf "${ATST_PROC_ROOT:?}/123" ;;
      c) atst_test_set_config ATST_AUTO_ATTACH_EA 0 ;;
      d) set_st "MONITORING_A_MT4,1,$(( now - 200 ))" "MONITORING_AUTO_ATTACH_A_MT4,1,$now" ;;
      e) SH_ETIMES=300 ;;
    esac
    run_sh
    [ "$status" -eq 0 ]
    not_called
    [ "$(err_lines)" -le 1 ]
    if [ "$g" != b ]; then
      [ "$(err_lines)" -eq 1 ]
    fi
    [ ! -e "$SL" ]
  done
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "SH-08f: the notice 180 s ago opens the gate, 175 s ago does not (AC8)" {
  pre_m
  set_st "MONITORING_A_MT4,1,$(( now - 180 ))"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
  rm -f "$SL" "$CALLS"
  set_st "MONITORING_A_MT4,1,$(( now - 175 ))"
  run_sh
  not_called
  [ "$(err_lines)" -eq 1 ]
}

@test "SH-08g: a process up 360 s opens the gate, 359 s or an unknown age does not (AC8)" {
  local v
  pre_m
  SH_ETIMES=360
  run_sh
  [ "$(mt_calls)" -eq 1 ]
  for v in 359 abc; do
    rm -f "$SL" "$CALLS"
    SH_ETIMES=$v
    run_sh
    not_called
    [ "$(err_lines)" -eq 1 ]
  done
}

@test "SH-09: TICK only is never acted on (AC9)" {
  enable
  set_st "TICK_A_MT4,1,$now" "PROCESS_A_MT4,0,$now" "MONITORING_A_MT4,0,$now"
  run_sh
  [ "$status" -eq 0 ]
  not_called
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(grep -c 'TICK_' "$repo/self_heal.sh")" -eq 0 ]
}

@test "SH-10: within 1800 s of a begin nothing is done; other MTs, ok / fail only and broken lines do not count (AC10)" {
  local v
  pre_p
  echo "$(( now - 600 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  run_sh
  not_called 1
  [ "$(err_lines)" -eq 1 ]
  for v in old other okfail broken; do
    rm -f "$CALLS"
    case $v in
      old) echo "$(( now - 1900 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL" ;;
      other) echo "$(( now - 600 )),B_MT5,PROCESS_B_MT5,start,begin" > "$SL" ;;
      okfail) printf '%s\n' "$(( now - 600 )),A_MT4,PROCESS_A_MT4,start,ok" "$(( now - 500 )),A_MT4,PROCESS_A_MT4,start,fail" > "$SL" ;;
      broken) printf '%s\n' "abc,A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 600 )),A_MT4,begin" > "$SL" ;;
    esac
    run_sh
    [ "$status" -eq 0 ]
    [ "$(mt_calls)" -eq 1 ]
  done
}

@test "SH-10b: a begin 1800 s ago is past the cooldown, 1795 s ago is not (AC10)" {
  pre_p
  echo "$(( now - 1800 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
  rm -f "$CALLS"
  echo "$(( now - 1795 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  run_sh
  not_called 1
}

@test "SH-11: 3 begins in 24 h: one halt line and one 【自己修復停止】, never again; past 24 h it acts again (AC11)" {
  pre_p
  printf '%s\n' "$(( now - 80000 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 40000 )),A_MT4,PROCESS_A_MT4,start,begin" \
    "$(( now - 2000 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  run_sh
  [ "$status" -eq 0 ]
  [ "$(mt_calls)" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  pushes | grep -q '【自己修復停止】A_MT4: 24 時間に 3 回再起動しても直らないため、自己修復を止めています（人の確認が必要です）'
  tail -1 "$SL" | grep -qE '^[0-9]+,A_MT4,PROCESS_A_MT4,start,halt$'
  [ "$(grep -c 'SELF_HEAL_' "$ST")" -eq 0 ]

  run_sh
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c ',halt$' "$SL")" -eq 1 ]
  [ "$(mt_calls)" -eq 0 ]

  sed -i "1s/^[0-9]*,/$(( now - 90000 )),/" "$SL"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
  [ "$(tail -2 "$SL" | head -1 | cut -d, -f5)" = begin ]
  [ "$(tail -1 "$SL" | cut -d, -f5)" = ok ]
  [ "$(atst_test_push_count)" -eq 2 ]
  pushes | tail -1 | grep -q '【自己修復】A_MT4: MT プロセス停止のため MetaTrader を起動しました (直近 24 時間で 3/3 回目)'
  [ "$(pushes | grep -c '【自己修復停止】')" -eq 1 ]
}

@test "SH-11b: a halt older than the last begin notifies again; one newer does not (AC11)" {
  pre_p
  printf '%s\n' "$(( now - 80000 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 40000 )),A_MT4,PROCESS_A_MT4,start,begin" \
    "$(( now - 30000 )),A_MT4,PROCESS_A_MT4,start,halt" "$(( now - 2000 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  run_sh
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c ',halt$' "$SL")" -eq 2 ]
  [ "$(mt_calls)" -eq 0 ]

  printf '%s\n' "$(( now - 80000 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 40000 )),A_MT4,PROCESS_A_MT4,start,begin" \
    "$(( now - 2000 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 1000 )),A_MT4,PROCESS_A_MT4,start,halt" > "$SL"
  run_sh
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(err_lines)" -eq 1 ]
  [ "$(sl_lines)" -eq 4 ]
  [ "$(mt_calls)" -eq 0 ]
}

@test "SH-11c: a begin 86400 s ago is out of the 24 h, 86395 s ago is in (AC11)" {
  pre_p
  printf '%s\n' "$(( now - 86400 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 40000 )),A_MT4,PROCESS_A_MT4,start,begin" \
    "$(( now - 2000 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
  pushes | grep -q '3/3 回目'
  rm -f "$CALLS"
  printf '%s\n' "$(( now - 86395 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 40000 )),A_MT4,PROCESS_A_MT4,start,begin" \
    "$(( now - 2000 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  run_sh
  [ "$(mt_calls)" -eq 0 ]
  tail -1 "$SL" | grep -q ',halt$'
}

@test "SH-12: two MetaTraders due: one per run, A first, then B (AC12)" {
  atst_test_make_mt B_MT5 MT5
  enable
  set_st "PROCESS_A_MT4,1,$(( now - 60 ))" "PROCESS_B_MT5,1,$(( now - 60 ))"
  run_sh A_MT4 B_MT5
  [ "$(calls)" = "mtctl.sh [-q] [start] [A_MT4]" ]
  [ "$(grep -c ',begin$' "$SL")" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  run_sh A_MT4 B_MT5
  [ "$(calls)" = "mtctl.sh [-q] [start] [A_MT4]
mtctl.sh [-q] [start] [B_MT5]" ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qE '^[0-9]+,B_MT5,PROCESS_B_MT5,start,begin$' "$SL"
}

@test "SH-13: restart that cannot stop the process (exit 1): the failure message with the pid, a fail line (AC13)" {
  pre_m
  atst_test_stub_script "$home" mtctl.sh exit1
  run_sh
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  pushes | grep -q '【自己修復】A_MT4: 再起動に失敗しました（プロセスを止められません。pid=123）(直近 24 時間で 1/3 回目)'
  tail -1 "$SL" | grep -qE ',restart,fail$'
  [ "$(err_lines)" -ge 1 ]
}

@test "SH-14: a hung mtctl.sh cut off by timeout leaves the begin line only and sends nothing (AC13)" {
  local t0 ms rc
  pre_p
  atst_test_stub_script "$home" mtctl.sh hang
  t0=$(date +%s%N)
  run timeout 3 bash "$home/self_heal.sh" A_MT4
  rc=$status
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  [ "$rc" -eq 124 ]
  [ "$ms" -lt 5000 ]
  [ "$(sl_lines)" -eq 1 ]
  grep -qE ',PROCESS_A_MT4,start,begin$' "$SL"
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "SH-15: the messages have no sandbox path, home path or token (AC15)" {
  pre_p
  run_sh
  rm -f "$CALLS"
  sed -i '/^PROCESS_/d' "$ST"
  rm -f "$SL"
  pre_m
  atst_test_stub_script "$home" mtctl.sh exit1
  run_sh
  printf '%s\n' "$(( now - 80000 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 40000 )),A_MT4,PROCESS_A_MT4,start,begin" \
    "$(( now - 2000 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  set_st "PROCESS_A_MT4,1,$(( now - 60 ))"
  rm -rf "${ATST_PROC_ROOT:?}/123"
  run_sh
  [ "$(atst_test_push_count)" -eq 3 ]
  [ "$(pushes | grep -c '自己修復')" -eq 3 ]
  [ "$(pushes | grep -cF "$ATST_TEST_SANDBOX")" -eq 0 ]
  [ "$(pushes | grep -c 'Bearer')" -eq 0 ]
  [ "$(pushes | grep -c '/home/')" -eq 0 ]
}

@test "SH-16: no kill in self_heal.sh / check_all.sh, only check_all.sh names self_heal.sh, usage without names (AC16)" {
  [ "$(grep -c 'kill ' "$repo/self_heal.sh")" -eq 0 ]
  [ "$(grep -c 'kill ' "$repo/check_all.sh")" -eq 0 ]
  [ "$(cd "$repo" && grep -lE 'self_heal\.sh' ./*.sh)" = "./check_all.sh" ]
  run bash -c 'bash "$1" 2>"$2"' _ "$home/self_heal.sh" "$E"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q Usage "$E"
}

@test "SH-17: while mtctl.sh holds the MT lock nothing is done (busy) (AC7)" {
  pre_p
  hold_lock "$LK" || return 1
  run_sh
  [ "$status" -eq 0 ]
  not_called
  [ ! -e "$SL" ]
  [ "$(err_lines)" -eq 1 ]
  grep -q busy "$E"
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "SH-18: a start stamp 60 s old holds off, 600 s old does not (AC7)" {
  pre_p
  echo "$(( now - 60 ))" > "$LK"
  run_sh
  not_called
  [ "$(err_lines)" -eq 1 ]
  echo "$(( now - 600 ))" > "$LK"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
}

@test "SH-18b: a stamp 180 s old is past the grace, 175 s is not, a non-number is ignored (AC7)" {
  pre_p
  echo "$(( now - 180 ))" > "$LK"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
  rm -f "$CALLS" "$SL"
  echo "$(( now - 175 ))" > "$LK"
  run_sh
  not_called
  echo abc > "$LK"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
}

@test "SH-19: an OS up 100 s holds off, 9999 s does not (AC7)" {
  pre_p
  echo "100.00 50.00" > "$ATST_PROC_ROOT/uptime"
  run_sh
  not_called
  [ ! -e "$SL" ]
  [ "$(err_lines)" -eq 1 ]
  echo "9999.00 1.00" > "$ATST_PROC_ROOT/uptime"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
}

@test "SH-19b: uptime 180.00 is past the grace, 179.99 is not, xyz is ignored (AC7)" {
  pre_p
  echo "180.00 1.00" > "$ATST_PROC_ROOT/uptime"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
  rm -f "$CALLS" "$SL"
  echo "179.99 1.00" > "$ATST_PROC_ROOT/uptime"
  run_sh
  not_called
  echo "xyz 1.00" > "$ATST_PROC_ROOT/uptime"
  run_sh
  [ "$(mt_calls)" -eq 1 ]
}

@test "SH-20: self_heal.log as a symlink: nothing is done, one line, the target untouched (AC11)" {
  pre_p
  : > "$ATST_TEST_SANDBOX/elsewhere"
  ln -s "$ATST_TEST_SANDBOX/elsewhere" "$SL"
  run_sh
  [ "$status" -eq 0 ]
  [ "$(mt_calls)" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(err_lines)" -eq 1 ]
  [ ! -s "$ATST_TEST_SANDBOX/elsewhere" ]
}

@test "SH-21: an ATST_TARGETS name reported missing (TARGET_) is skipped (AC7)" {
  pre_p
  echo "TARGET_A_MT4,1,$now" >> "$ST"
  run_sh
  not_called
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "SH-22: mtctl.sh exit 2 (busy) gives the busy message and a fail line (AC13)" {
  pre_m
  sed -i '$d' "$home/mtctl.sh"
  echo 'exit 2' >> "$home/mtctl.sh"
  run_sh
  [ "$(atst_test_push_count)" -eq 1 ]
  pushes | grep -q '【自己修復】A_MT4: ほかの起動・再起動の最中だったため何もしませんでした (直近 24 時間で 1/3 回目)'
  tail -1 "$SL" | grep -qE ',restart,fail$'
}

@test "SH-23: the P1 exception for self_heal comes first in CODING_GUIDELINES (AC1)" {
  [ "$(sed -n '/^## P1/,/^## P2/p' "$repo/docs/CODING_GUIDELINES.md" | grep -c self_heal)" -ge 1 ]
}

@test "SH-24: check_all.sh runs self_heal last, after the heartbeat and before the last flush (AC14)" {
  local f="$repo/check_all.sh" sh hb fl
  [ "$(grep -c 'run_check "\$self_heal_cap" self_heal' "$f")" -eq 1 ]
  sh=$(grep -n 'run_check "\$self_heal_cap" self_heal' "$f" | cut -d: -f1)
  hb=$(grep -n 'run_check "\$heartbeat_cap" heartbeat' "$f" | cut -d: -f1)
  fl=$(grep -n '^atst_spool_flush 1$' "$f" | tail -1 | cut -d: -f1)
  [ "$sh" -gt "$hb" ]
  [ "$sh" -lt "$fl" ]
  [ "$(grep -c 'RUNNER_TIMEOUT_SELF_HEAL\|notify_timeout SELF_HEAL' "$f")" -ge 1 ]
  sed -n '/^# The longest one run/,/^stuck_after=/p' "$f" | grep -q self_heal
  grep -q '11 \* cap + 975' "$f"
}

@test "SH-25: an MT lock that cannot be opened: nothing is done (AC7)" {
  pre_p
  mkdir -p "$LK"
  run_sh
  [ "$status" -eq 0 ]
  not_called
  [ ! -e "$SL" ]
  [ "$(err_lines)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "SH-26b: a self_heal.log that can be written but not read: no mtctl.sh, the limits are not bypassed" {
  pre_p
  printf '%s\n' "$(( now - 80000 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 40000 )),A_MT4,PROCESS_A_MT4,start,begin" \
    "$(( now - 2000 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  chmod 200 "$SL"
  run_sh
  chmod 600 "$SL"
  [ "$(mt_calls)" -eq 0 ]
  [ "$(err_lines)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(wc -l < "$SL")" -eq 3 ]
}

@test "SH-26: a self_heal.log that cannot be written: no mtctl.sh, and no stop notice every minute (AC11)" {
  pre_p
  echo "$(( now - 5000 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  chmod 400 "$SL"
  run_sh
  [ "$(mt_calls)" -eq 0 ]
  [ "$(err_lines)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 0 ]

  chmod 600 "$SL"
  printf '%s\n' "$(( now - 80000 )),A_MT4,PROCESS_A_MT4,start,begin" "$(( now - 40000 )),A_MT4,PROCESS_A_MT4,start,begin" \
    "$(( now - 2000 )),A_MT4,PROCESS_A_MT4,start,begin" > "$SL"
  chmod 400 "$SL"
  run_sh
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(err_lines)" -eq 1 ]
  run_sh
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(mt_calls)" -eq 0 ]
}
