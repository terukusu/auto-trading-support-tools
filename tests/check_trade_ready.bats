#!/usr/bin/env bats
# check_trade_ready.sh (#158): TRADE_<MT> fires when fields 9 to 12 of the monitoring csv (connected,
# the terminal's auto trading button, the account's trade and EA permissions) are bad (any of them 0) on
# every complete line of the window of ATST_TRADE_READY_THRESHOLD seconds cut by field 1, and recovers
# when they are all 1. Mixed keeps the state. Not judged: no csv / no 14-field line (an old EA), a stopped
# csv (ATST_MONITORING_THRESHOLD), the weekend (field 1 in UTC, Fri 20:00 to Mon 00:00), a window not full
# yet, a gap of ATST_MONITORING_THRESHOLD seconds or more in the window (just back after a stop).
# Single rows are made with atst_test_make_monitoring_csv (8th argument = fields 9 and on), runs of rows
# every 60 seconds (as the EA writes them, without a gap) with span / span_abs; oldest first. The
# "date +%s" of each call may move on by a few seconds, which only makes a row later than asked; the
# boundary tests take "now" once and write absolute epochs.
# Tests made from "now" turn the weekend gate off in setup so they do not depend on the day they run;
# the weekend tests turn it back on with ATST_TRADE_READY_WEEKEND_SKIP (the last line of the config wins).
# TR-xx / DUP-xx are the IDs of the verification items.

load test_helper

FIRE_CONN='【発生】A_MT4 が 5 分以上取引できない状態です: ブローカーに接続していません。この間は自動売買が動きません（MetaTrader は動いていて監視データは更新されています）。'
REC='【復帰】A_MT4 が取引できる状態に戻りました。'
BADT='check_trade_ready.sh: ATST_TRADE_READY_THRESHOLD is not a number of seconds from 60 to 86400; using 300'
R9='ブローカーに接続していません'
R10='端末の自動売買ボタンが OFF です'
R11='口座で取引が許可されていません（閲覧専用のログインなど）'
R12='口座で EA の取引が許可されていません'

setup() {
  atst_test_setup_sandbox
  atst_test_make_mt A_MT4 MT4
  S="$BATS_TEST_DIRNAME/../check_trade_ready.sh"
  ST="$HOME/.atst/alert_status"
  C="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
  atst_test_set_config ATST_TRADE_READY_WEEKEND_SKIP 0
}

teardown() {
  atst_test_teardown_sandbox
}

tr_run() {
  run bash "$S" A_MT4
}

# row <secs_ago> <c9..c12> [<c13> [<c14>]]: one 14-field line, field 2 = 100.
row() {
  atst_test_make_monitoring_csv A_MT4 "$1" 150.0 10 0.01 12 100 "$2,${3:-0},${4:-0.00}"
}

# row8 <secs_ago>: one 8-field line of an old EA.
row8() {
  atst_test_make_monitoring_csv A_MT4 "$1" 150.0 10 0.01 12 100
}

# span_abs <mt> <from_epoch> <to_epoch> <c9..c12> [<c13,c14>]: 14-field rows every 60 seconds from
# <from_epoch>, and one at <to_epoch>. Field 2 is $C2 (default 100; "t" = field 1, a moving tick).
span_abs() {
  local f="$WINEPREFIX/drive_c/Program Files/$1/MQL4/Files/terminal_monitoring.csv"
  mkdir -p "$(dirname "$f")"
  awk -v a="$2" -v b="$3" -v v="$4" -v x="${5:-0,0.00}" -v c2="${C2:-100}" '
    function p(t) { printf "%.0f,%s,150.0,150.0,10,12,0.01,USDJPY,%s,%s\n", t, (c2 == "t" ? sprintf("%.0f", t) : c2), v, x }
    BEGIN { for (t = a; t < b; t += 60) p(t); p(b) }' >> "$f"
}

# span <from_ago> <to_ago> <c9..c12> [<mt> [<c13,c14>]]: span_abs counted back from now.
span() {
  local n
  n=$(date +%s)
  span_abs "${4:-A_MT4}" $(( n - $1 )) $(( n - $2 )) "$3" "${5:-}"
}

# span8_abs <from_epoch> <to_epoch>: 8-field rows of an old EA every 60 seconds and one at <to_epoch>.
span8_abs() {
  mkdir -p "$(dirname "$C")"
  awk -v a="$1" -v b="$2" 'BEGIN {
    for (t = a; t < b; t += 60) printf "%.0f,100,150.0,150.0,10,12,0.01,USDJPY\n", t
    printf "%.0f,100,150.0,150.0,10,12,0.01,USDJPY\n", b
  }' >> "$C"
}

# span8 <from_ago> <to_ago>
span8() {
  local n
  n=$(date +%s)
  span8_abs $(( n - $1 )) $(( n - $2 ))
}

# state <0|1>: how many TRADE_A_MT4 lines have that value.
state() {
  grep -c "^TRADE_A_MT4,$1," "$ST" 2>/dev/null || true
}

no_trade() {
  [ ! -e "$ST" ] || ! grep -q '^TRADE_' "$ST"
}

reset() {
  rm -f "$C" "$ST" "$ATST_TEST_CURL_LOG"
}

# The weekend times in UTC, a week back so they are in the past whatever today is (as check_tick.bats).
wk_times() {
  sat=$(( $(date -u -d 'last saturday 12:00' +%s) - 604800 ))
  [ "$(date -u -d "@$sat" '+%u %H%M')" = "6 1200" ]
  fri1959=$(( sat - 57660 ))
  fri2000=$(( sat - 57600 ))
  sun2359=$(( sat + 129540 ))
  mon0000=$(( sat + 129600 ))
  atst_test_set_config ATST_MONITORING_THRESHOLD 99999999
  atst_test_set_config ATST_TRADE_READY_WEEKEND_SKIP 1
}

# wk_rows <epoch> <c9..c12>: rows every 60 s from 700 to 60 seconds before <epoch>, and one at <epoch>.
wk_rows() {
  span_abs A_MT4 $(( $1 - 700 )) $(( $1 - 60 )) "$2"
  span_abs A_MT4 "$1" "$1" "$2"
}

drop_threshold() {
  sed -i '/^ATST_TRADE_READY_THRESHOLD=/d' "$HOME/.atst/config"
}

@test "TR-01: executable; no argument prints the usage (2 lines) on stderr only and exits 1, before the settings" {
  test -x "$S"
  atst_test_set_config ATST_TRADE_READY_THRESHOLD abc
  run bash "$S"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = 'Usage: check_trade_ready.sh <MetaTrader Name1> <MetaTrader Name2> ...' ]
  [[ "$output" != *ATST_TRADE_READY_THRESHOLD* ]]
  run bash -c 'bash "$1" 2>/dev/null' _ "$S"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "TR-02 (T1): fields 9-12 all 1 in the window: nothing sent, no state" {
  span 700 0 1,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-03 (T2): field 9 = 0 in the whole window: one 【発生】, and only once; nothing on stdout" {
  span 700 0 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -cF "$FIRE_CONN" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  run bash -c 'bash "$1" A_MT4 2>/dev/null' _ "$S"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "TR-04 (T3): the window all good again sends one 【復帰】" {
  span 700 0 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  rm -f "$C"
  span 700 360 0,1,1,1
  span 300 0 1,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(grep -cF "$REC" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(state 0)" -eq 1 ]
  [ "$(state 1)" -eq 0 ]
}

@test "TR-05 (T4): good and bad lines mixed in the window keep the state (none, or 1)" {
  span 700 200 1,1,1,1
  span 150 0 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
  reset
  mkdir -p "$HOME/.atst"
  printf 'TRADE_A_MT4,1,%s\n' "$(date +%s)" > "$ST"
  cp "$ST" "$ST.bak"
  span 700 200 1,1,1,1
  span 150 0 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(state 1)" -eq 1 ]
  cmp "$ST" "$ST.bak"
}

@test "TR-06 (T5): the reason for field 10, 11, 12 alone and for 9 and 10" {
  local c r
  for c in "1,0,1,1|: $R10。" "1,1,0,1|: $R11。" "1,1,1,0|: $R12。" "0,0,1,1|: $R9、$R10。"; do
    reset
    r=${c#*|}
    span 700 0 "${c%%|*}"
    tr_run
    [ "$status" -eq 0 ] || { echo "c=$c status=$status"; false; }
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "c=$c pushed=$(atst_test_push_count)"; false; }
    grep -qF "$r" "$ATST_TEST_CURL_LOG" || { echo "c=$c no reason"; false; }
  done
}

@test "TR-07 (D4): while disconnected the account reasons are not given; the button is" {
  local c
  for c in 0,1,0,1 0,1,1,0; do
    reset
    span 700 0 "$c"
    tr_run
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "c=$c pushed=$(atst_test_push_count)"; false; }
    grep -qF ": $R9。" "$ATST_TEST_CURL_LOG" || { echo "c=$c no R9"; false; }
    ! grep -qF '口座で' "$ATST_TEST_CURL_LOG" || { echo "c=$c account reason"; false; }
  done
  reset
  span 700 0 0,0,0,0
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF ": $R9、$R10。" "$ATST_TEST_CURL_LOG"
  ! grep -qF '口座で' "$ATST_TEST_CURL_LOG"
}

@test "TR-08 (F5): the reason comes from the last complete line" {
  span 700 60 0,1,1,1
  row 0 1,0,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF ": $R10。" "$ATST_TEST_CURL_LOG"
  ! grep -qF "$R9" "$ATST_TEST_CURL_LOG"
}

@test "TR-09 (T6): an old EA (8 fields) does nothing; 8-field lines are not counted outside the window nor in the gaps" {
  # (a) 8-field lines only
  span8 700 0
  tr_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ ! -e "$ST" ]
  # (b) 8-field lines before, then 14-field bad lines for 250 s: no 14-field line outside the window
  reset
  span8 700 310
  span 250 0 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
  # (c) 14-field bad lines every 60 s with an 8-field line between each two (two EAs writing)
  reset
  local n t
  n=$(date +%s)
  for (( t = n - 700; t <= n; t += 60 )); do
    span_abs A_MT4 "$t" "$t" 0,1,1,1
    [ "$t" -lt "$n" ] && span8_abs $(( t + 30 )) $(( t + 30 ))
  done
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TR-10 (T7): no csv / only broken lines / nothing outside the window / a stopped csv: not judged" {
  # (a) no csv
  tr_run
  [ "$status" -eq 0 ]; [ -z "$output" ]; [ "$(atst_test_push_count)" -eq 0 ]; no_trade
  # (b) only broken lines
  reset
  mkdir -p "$(dirname "$C")"
  printf 'x,100,1,1,1,1,1,U,0,1,1,1,0,0.00\n' >> "$C"
  printf '%s,100,1,1,1,1,1,U,x,1,1,1,0,0.00\n' "$(date +%s)" >> "$C"
  printf '\n' >> "$C"
  printf '17' >> "$C"
  tr_run
  [ "$status" -eq 0 ]; [ -z "$output" ]; [ "$(atst_test_push_count)" -eq 0 ]; no_trade
  # (c) the window is not full yet
  reset
  row 250 0,1,1,1; row 0 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]; [ -z "$output" ]; [ "$(atst_test_push_count)" -eq 0 ]; no_trade
  # (d) the last line is 200 s old (>= ATST_MONITORING_THRESHOLD 180)
  reset
  span 1000 200 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]; [ -z "$output" ]; [ "$(atst_test_push_count)" -eq 0 ]; no_trade
  # (e) not judged does not recover an alert
  reset
  mkdir -p "$HOME/.atst"
  printf 'TRADE_A_MT4,1,%s\n' "$(date +%s)" > "$ST"
  row 250 1,1,1,1; row 0 1,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TR-11 (T8): Saturday 12:00, Friday 20:00 and Sunday 23:59 UTC are not judged; Friday 19:59 and Monday 00:00 are" {
  local c
  wk_times
  for c in "$sat|0" "$fri1959|1" "$fri2000|0" "$sun2359|0" "$mon0000|1"; do
    reset
    wk_rows "${c%%|*}" 0,1,1,1
    tr_run
    [ "$status" -eq 0 ] || { echo "c=$c status=$status"; false; }
    [ "$(atst_test_push_count)" -eq "${c#*|}" ] || { echo "c=$c pushed=$(atst_test_push_count)"; false; }
  done
}

@test "TR-12 (T8): ATST_TRADE_READY_WEEKEND_SKIP=0 judges the weekend; any other value (00, abc, empty, 1) does not" {
  local v
  wk_times
  wk_rows "$sat" 0,1,1,1
  atst_test_set_config ATST_TRADE_READY_WEEKEND_SKIP 0
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  for v in 00 abc '' 1; do
    reset
    wk_rows "$sat" 0,1,1,1
    atst_test_set_config ATST_TRADE_READY_WEEKEND_SKIP "$v"
    tr_run
    [ "$status" -eq 0 ] || { echo "v=$v status=$status"; false; }
    [ "$(atst_test_push_count)" -eq 0 ] || { echo "v=$v pushed"; false; }
    [ -z "$output" ] || { echo "v=$v output=$output"; false; }
  done
}

@test "TR-13: without any ATST_TRADE_READY_WEEKEND_SKIP line (the default 1) Saturday is not judged" {
  wk_times
  sed -i '/^ATST_TRADE_READY_WEEKEND_SKIP=/d' "$HOME/.atst/config"
  ! grep -q 'ATST_TRADE_READY_WEEKEND_SKIP' "$HOME/.atst/config"
  wk_rows "$sat" 0,1,1,1
  run env -u ATST_TRADE_READY_WEEKEND_SKIP bash "$S" A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-W5: ATST_TICK_WEEKEND_SKIP=0 does not turn the trade-ready weekend gate off" {
  wk_times
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
  wk_rows "$sat" 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-14 (T9): without ATST_TRADE_READY_THRESHOLD the window is 300 s (good 290 / 320 s ago)" {
  drop_threshold
  # (a) a good line 290 s ago is inside the window: mixed
  span 900 290 1,1,1,1
  span 289 0 0,1,1,1
  run env -u ATST_TRADE_READY_THRESHOLD bash "$S" A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  # (b) good until 320 s ago, bad after: fired
  reset
  span 900 320 1,1,1,1
  span 310 0 0,1,1,1
  run env -u ATST_TRADE_READY_THRESHOLD bash "$S" A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -cF "$FIRE_CONN" "$ATST_TEST_CURL_LOG")" -eq 1 ]
}

@test "TR-15 (T9): abc 30 59 86401 060 +300 empty and a newline use 300 with one stderr line (no value)" {
  local v
  for v in abc 30 59 86401 060 +300 '' $'3\n00'; do
    reset
    drop_threshold
    atst_test_set_config ATST_TRADE_READY_THRESHOLD "$v"
    span 700 0 0,1,1,1
    tr_run
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "v=$v pushed=$(atst_test_push_count)"; false; }
    grep -qF 'が 5 分以上' "$ATST_TEST_CURL_LOG" || { echo "v=$v not 300"; false; }
    [ "$output" = "$BADT" ] || { echo "v=$v output=$output"; false; }
  done
}

@test "TR-16: 60 and 86400 are taken" {
  drop_threshold
  atst_test_set_config ATST_TRADE_READY_THRESHOLD 60
  span 400 0 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF 'が 1 分以上' "$ATST_TEST_CURL_LOG"
  [ -z "$output" ]

  reset
  drop_threshold
  atst_test_set_config ATST_TRADE_READY_THRESHOLD 86400
  span 90000 0 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF 'が 1440 分以上' "$ATST_TEST_CURL_LOG"
  [ -z "$output" ]
}

@test "TR-17: an invalid ATST_TRADE_READY_THRESHOLD is one stderr line per run, with two MetaTraders or none found" {
  atst_test_make_mt B_MT4 MT4
  span 700 0 0,1,1,1
  span 700 0 0,1,1,1 B_MT4
  atst_test_set_config ATST_TRADE_READY_THRESHOLD abc
  run bash "$S" A_MT4 B_MT4
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$output" = "$BADT" ]
  run bash "$S" NOSUCH
  [ "$status" -eq 0 ]
  [ "$output" = "$BADT" ]
}

@test "TR-18 (T10): no path, token, price, symbol or field 14; field 13 only as 建玉 N 件 (#177)" {
  span 700 0 0,1,1,1 A_MT4 7,123.45
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  rm -f "$C"
  span 700 360 0,1,1,1 A_MT4 7,123.45
  span 300 0 1,1,1,1 A_MT4 7,123.45
  tr_run
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF "$REC" "$ATST_TEST_CURL_LOG"
  grep -qF '建玉 7 件' "$ATST_TEST_CURL_LOG"
  [ "$(grep -cF "$ATST_TEST_SANDBOX" "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep -c Bearer "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep -cF 150.0 "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep -cF 123.45 "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep -cF ',7,' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep -cF USDJPY "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep -cF terminal_monitoring "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "TR-19 (T11): the key is the folder name with spaces as _" {
  atst_test_make_mt 'A B' MT4
  span 700 0 0,1,1,1 'A B'
  run bash "$S" 'A B'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^TRADE_A_B,1,' "$ST")" -eq 1 ]
  grep -qF '【発生】A B が 5 分以上取引できない状態です' "$ATST_TEST_CURL_LOG"
}

@test "TR-20: each MetaTrader has its own key" {
  atst_test_make_mt B_MT4 MT4
  span 700 0 0,1,1,1
  span 700 0 1,1,1,1 B_MT4
  run bash "$S" A_MT4 B_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^TRADE_A_MT4,1,' "$ST")" -eq 1 ]
  [ "$(grep -c '^TRADE_B_MT4' "$ST")" -eq 0 ]
}

@test "TR-21: a name matching no MetaTrader does nothing" {
  run bash "$S" NOSUCH
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$ST" ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "TR-22: a line exactly at the lower end of the window (last1 - T) is inside it" {
  local n
  n=$(date +%s)
  span_abs A_MT4 $(( n - 900 )) $(( n - 360 )) 1,1,1,1
  span_abs A_MT4 $(( n - 300 )) "$n" 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  reset
  span_abs A_MT4 $(( n - 900 )) $(( n - 300 )) 1,1,1,1
  span_abs A_MT4 $(( n - 240 )) "$n" 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-23: lines from last1 - T only are not enough; one line 1 s before makes the window full" {
  local n
  n=$(date +%s)
  span_abs A_MT4 $(( n - 300 )) "$n" 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
  reset
  span_abs A_MT4 $(( n - 301 )) $(( n - 301 )) 0,1,1,1
  span_abs A_MT4 $(( n - 300 )) "$n" 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TR-24 (B1a): back after a stop, one bad line: not judged" {
  span 2400 1200 1,1,1,1
  row 10 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-25 (B1b): back after a stop, T seconds of bad lines without a gap: fired" {
  span 2400 1200 1,1,1,1
  span 700 0 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TR-26: a gap of exactly ATST_MONITORING_THRESHOLD (180) before the window is not judged; 179 is" {
  local n
  n=$(date +%s)
  span_abs A_MT4 $(( n - 900 )) $(( n - 480 )) 0,1,1,1
  span_abs A_MT4 $(( n - 300 )) "$n" 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
  reset
  span_abs A_MT4 $(( n - 900 )) $(( n - 479 )) 0,1,1,1
  span_abs A_MT4 $(( n - 300 )) "$n" 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TR-27: a gap in the window is not judged; ATST_MONITORING_THRESHOLD 1000 judges it, invalid values use 180 silently" {
  span 900 400 0,1,1,1
  span 200 0 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
  atst_test_set_config ATST_MONITORING_THRESHOLD abc
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  [ -z "$output" ]
  atst_test_set_config ATST_MONITORING_THRESHOLD 99999999999
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  [ -z "$output" ]
  atst_test_set_config ATST_MONITORING_THRESHOLD 1000
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TR-28: the last line 170 s old is judged, 190 s old is not (MONITORING_ reports it)" {
  span 900 170 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  reset
  span 900 190 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-29: fields 9-12 other than exactly 0 or 1 make the line incomplete (not bad, not good)" {
  local n v
  n=$(date +%s)
  span 700 0 0,1,1,1
  for v in 2 01 -1 '' x 1.0 ' 1'; do
    printf '%s,100,150.0,150.0,10,12,0.01,USDJPY,%s,1,1,1,0,0.00\n' "$n" "$v" >> "$C"
    printf '%s,100,150.0,150.0,10,12,0.01,USDJPY,1,1,1,%s,0,0.00\n' "$n" "$v" >> "$C"
  done
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF ": $R9。" "$ATST_TEST_CURL_LOG"
  reset
  span 700 0 1,1,1,1
  for v in 2 01 -1 '' x 1.0 ' 1'; do
    printf '%s,100,150.0,150.0,10,12,0.01,USDJPY,%s,0,0,0,0,0.00\n' "$n" "$v" >> "$C"
  done
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-30: short lines and a half-written line are not complete" {
  local n
  n=$(date +%s)
  span 700 0 0,1,1,1
  printf '%s,100,1,1,1,1,1,U,1,1\n' "$n" >> "$C"
  printf '%s,100,1,1,1,1,1,U,1,1,1,1,0\n' "$n" >> "$C"
  printf '%s,100,150.0,150.0,10,12,0.01,USDJPY,1,1,1,\n' "$n" >> "$C"
  printf '%s' "${n:0:5}" >> "$C"
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  grep -qF ": $R9。" "$ATST_TEST_CURL_LOG"
}

@test "TR-31: CRLF lines: field 12 = 0 before the CR is bad; all good CRLF lines are good" {
  span 700 0 1,1,1,0
  sed -i 's/$/\r/' "$C"
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF ": $R12。" "$ATST_TEST_CURL_LOG"
  reset
  span 700 0 0,1,1,1
  sed -i 's/$/\r/' "$C"
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF ": $R9。" "$ATST_TEST_CURL_LOG"
  reset
  span 700 0 1,1,1,1
  sed -i 's/$/\r/' "$C"
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-32: field 2 = 0 (no tick yet) does not matter here" {
  local a
  for a in 700 640 580 520 460 400 340 280 220 160 100 40 0; do
    atst_test_make_monitoring_csv A_MT4 "$a" 150.0 10 0.01 12 '' '0,1,1,1,0,0.00'
  done
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TR-33: lines newer than the last complete line (out of order) are not in the window" {
  # (a) a good line in the future before the last bad line: all bad (as TK-15)
  span 900 60 0,1,1,1
  row -100 1,1,1,1
  row 0 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  # (b) the last complete line is an older good line: the bad lines newer than it are out of the window,
  # the ones from last1 - T to last1 and the good line are in it (mixed); an 8-field line is not counted
  reset
  span 900 0 0,1,1,1
  row8 -100
  row 100 1,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_trade
}

@test "TR-34: a last line in the future (the Wine clock ahead) is still judged" {
  local n
  n=$(date +%s)
  span_abs A_MT4 $(( n - 600 )) $(( n + 30 )) 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TR-35: TRADE_ still 1 after 31 minutes is reminded once (#141)" {
  local e
  mkdir -p "$HOME/.atst"
  e=$(( $(date +%s) - 1860 ))
  printf 'TRADE_A_MT4,1,%s\n' "$e" > "$ST"
  span 700 0 0,1,1,1
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '【継続中 30 分】' "$ATST_TEST_CURL_LOG"
  grep -qF 'A_MT4 が 5 分以上取引できない状態です' "$ATST_TEST_CURL_LOG"
  [ "$(grep -c "^TRADE_A_MT4,1,$e,1$" "$ST")" -eq 1 ]
}

@test "TR-36: no reminder on the weekend (not judged), the line is unchanged" {
  local e
  wk_times
  mkdir -p "$HOME/.atst"
  e=$(( $(date +%s) - 1860 ))
  printf 'TRADE_A_MT4,1,%s\n' "$e" > "$ST"
  wk_rows "$sat" 0,1,1,1
  cp "$ST" "$ST.bak"
  tr_run
  [ "$(atst_test_push_count)" -eq 0 ]
  cmp "$ST" "$ST.bak"
}

@test "TR-37: an alert going into the weekend stays (no recovery there) and recovers on Monday" {
  wk_times
  wk_rows "$fri1959" 0,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  wk_rows "$sat" 1,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  wk_rows "$mon0000" 1,1,1,1
  tr_run
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(grep -cF "$REC" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(state 0)" -eq 1 ]
}

@test "TR-38: back to an old EA (8 fields) after an alert: the last 14-field line gets old, the state stays 1" {
  mkdir -p "$HOME/.atst"
  printf 'TRADE_A_MT4,1,%s\n' "$(date +%s)" > "$ST"
  span 1000 400 0,1,1,1
  span8 340 0
  tr_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(state 1)" -eq 1 ]
}

@test "DUP-01: a disconnection with field 2 stopped fires TICK_ and TRADE_ separately" {
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
  span 700 0 0,1,1,1
  run bash "$BATS_TEST_DIRNAME/../check_tick.sh" A_MT4
  tr_run
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(grep -c '^TICK_A_MT4,1,' "$ST")" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  [ "$(grep -cF "$FIRE_CONN" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(grep -cF '価格データ（ティック）が 10 分以上' "$ATST_TEST_CURL_LOG")" -eq 1 ]
}

@test "DUP-02: connected again with field 2 still stopped: TRADE_ recovers, TICK_ stays 1" {
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
  span 700 0 0,1,1,1
  run bash "$BATS_TEST_DIRNAME/../check_tick.sh" A_MT4
  tr_run
  [ "$(atst_test_push_count)" -eq 2 ]
  rm -f "$C"
  span 900 360 0,1,1,1
  span 300 0 1,1,1,1
  run bash "$BATS_TEST_DIRNAME/../check_tick.sh" A_MT4
  tr_run
  [ "$(atst_test_push_count)" -eq 3 ]
  [ "$(grep -cF "$REC" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(state 0)" -eq 1 ]
  [ "$(grep -c '^TICK_A_MT4,1,' "$ST")" -eq 1 ]
}

@test "DUP-03: ticks coming but the button OFF: TRADE_ only" {
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
  C2=t span 700 0 1,0,1,1
  run bash "$BATS_TEST_DIRNAME/../check_tick.sh" A_MT4
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  ! grep -q '^TICK_' "$ST"
  grep -qF ": $R10。" "$ATST_TEST_CURL_LOG"
}

@test "DUP-04: a stopped csv is reported by MONITORING_ only" {
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
  span 1000 400 0,1,1,1
  run bash "$BATS_TEST_DIRNAME/../check_monitoring.sh" A_MT4
  run bash "$BATS_TEST_DIRNAME/../check_tick.sh" A_MT4
  tr_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^MONITORING_A_MT4,1,' "$ST")" -eq 1 ]
  ! grep -q '^TICK_' "$ST"
  no_trade
}
