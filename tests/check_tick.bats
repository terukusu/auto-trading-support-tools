#!/usr/bin/env bats
# check_tick.sh (#137): TICK_<MT> fires when field 2 of the monitoring csv (the server time of the last
# tick) does not change inside the window of ATST_TICK_THRESHOLD seconds cut by field 1, and recovers
# when it changes. Not judged: no csv / no complete line, a stopped csv (ATST_MONITORING_THRESHOLD),
# the weekend (field 1 in UTC, Fri 20:00 to Mon 00:00), a window not full yet, a gap of
# ATST_MONITORING_THRESHOLD seconds or more in the window (just back after a stop), field 2 = 0.
# Single rows are made with atst_test_make_monitoring_csv (7th argument = field 2), runs of rows every
# 60 seconds (as the EA writes them, without a gap) with span / span_abs; oldest first. The "date +%s"
# of each call may move on by a few seconds, which only makes a row later than asked.
# Tests made from "now" turn the weekend gate off in setup so they do not depend on the day they run;
# the weekend tests turn it back on (the last line of the config wins).
# TK-xx / TH-xx are the IDs of the verification items (TH-04.. continue the TH- IDs of check_all.bats).

load test_helper

FIRE600='【発生】A_MT4 の価格データ（ティック）が 10 分以上更新されていません。ブローカーとの接続断・ログアウト・銘柄の配信停止の可能性があります（MetaTrader は動いていて監視データは更新されています）。この間は自動売買が動きません。'
REC='【復帰】A_MT4 の価格データ（ティック）の更新が再開しました。'
BADT='check_tick.sh: ATST_TICK_THRESHOLD is not a number of seconds from 60 to 86400; using 600'

setup() {
  atst_test_setup_sandbox
  atst_test_make_mt A_MT4 MT4
  S="$BATS_TEST_DIRNAME/../check_tick.sh"
  ST="$HOME/.atst/alert_status"
  C="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
}

teardown() {
  atst_test_teardown_sandbox
}

tick_run() {
  run bash "$S" A_MT4
}

# row <secs_ago> [<time_server>]: one complete line; field 2 is 0 without <time_server>.
row() {
  atst_test_make_monitoring_csv A_MT4 "$1" 150.0 10 0.01 12 "$2"
}

# span_abs <mt> <from_epoch> <to_epoch> <time_server>: rows every 60 seconds from <from_epoch>, and one
# at <to_epoch> (the same line format as atst_test_make_monitoring_csv).
span_abs() {
  local f="$WINEPREFIX/drive_c/Program Files/$1/MQL4/Files/terminal_monitoring.csv"
  mkdir -p "$(dirname "$f")"
  awk -v a="$2" -v b="$3" -v v="$4" 'BEGIN {
    for (t = a; t < b; t += 60) printf "%.0f,%s,150.0,150.0,10,12,0.01,USDJPY\n", t, v
    printf "%.0f,%s,150.0,150.0,10,12,0.01,USDJPY\n", b, v
  }' >> "$f"
}

# span <from_ago> <to_ago> <time_server> [<mt>]: span_abs counted back from now.
span() {
  local n
  n=$(date +%s)
  span_abs "${4:-A_MT4}" $(( n - $1 )) $(( n - $2 )) "$3"
}

# ago_of <epoch>: the secs_ago of <epoch>.
ago_of() {
  echo $(( $(date +%s) - $1 ))
}

# state <0|1>: how many TICK_A_MT4 lines have that value.
state() {
  grep -c "^TICK_A_MT4,$1," "$ST" 2>/dev/null || true
}

no_tick() {
  [ ! -e "$ST" ] || ! grep -q '^TICK_' "$ST"
}

reset() {
  rm -f "$C" "$ST" "$ATST_TEST_CURL_LOG"
}

# wk_rows <epoch> <v1> <v2>: rows every 60 s from 700 to 60 seconds before <epoch> with <v1>, one at
# <epoch> with <v2>.
wk_rows() {
  span_abs A_MT4 $(( $1 - 700 )) $(( $1 - 60 )) "$2"
  span_abs A_MT4 "$1" "$1" "$3"
}

# x_rows <X> [<mt>]: field 2 changes X seconds ago; the old value until 5 seconds before, so the change
# is seen only when both rows are inside the window.
x_rows() {
  span 900 $(( $1 + 5 )) 100 "${2:-A_MT4}"
  span "$1" 0 101 "${2:-A_MT4}"
}

# The weekend times in UTC, a week back so they are in the past whatever today is.
weekend_times() {
  sat=$(( $(date -u -d 'last saturday 12:00' +%s) - 604800 ))
  [ "$(date -u -d "@$sat" '+%u %H%M')" = "6 1200" ]
  fri1959=$(( sat - 57660 ))
  fri2000=$(( sat - 57600 ))
  sun1200=$(( sat + 86400 ))
  sun2359=$(( sat + 129540 ))
  mon0000=$(( sat + 129600 ))
  atst_test_set_config ATST_MONITORING_THRESHOLD 99999999
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 1
}

drop_threshold() {
  sed -i '/^ATST_TICK_THRESHOLD=/d' "$HOME/.atst/config"
}

@test "TK-01: executable; no argument prints the usage (2 lines) on stderr only and exits 1, before the settings" {
  test -x "$S"
  atst_test_set_config ATST_TICK_THRESHOLD abc
  run bash "$S"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = 'Usage: check_tick.sh <MetaTrader Name1> <MetaTrader Name2> ...' ]
  [[ "$output" != *ATST_TICK_THRESHOLD* ]]
  run bash -c 'bash "$1" 2>/dev/null' _ "$S"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "TK-02 (T1): field 2 changes inside the window: nothing sent, no state" {
  span 700 200 100; row 100 101; row 0 101
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick
}

@test "TK-03 (T2): field 2 unchanged inside the window: one 【発生】, and only once; nothing on stdout" {
  span 700 0 100
  tick_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -cF "$FIRE600" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  run bash -c 'bash "$1" A_MT4 2>/dev/null' _ "$S"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "TK-04 (T3) / TK-10 (T9): a changed field 2 sends one 【復帰】; no path, token or price in the notices" {
  span 700 0 100
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  row 0 101
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(grep -cF "$REC" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(state 0)" -eq 1 ]
  [ "$(state 1)" -eq 0 ]
  # TK-10 (T9)
  ! grep -qF "$ATST_TEST_SANDBOX" "$ATST_TEST_CURL_LOG"
  ! grep -q Bearer "$ATST_TEST_CURL_LOG"
  ! grep -qF 150.0 "$ATST_TEST_CURL_LOG"
  ! grep -qF terminal_monitoring "$ATST_TEST_CURL_LOG"
}

@test "TK-05 (T4): Saturday 12:00 and Friday 20:00 UTC are not judged, Friday 19:59 is" {
  weekend_times
  wk_rows "$sat" 5000 5000
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick

  reset
  wk_rows "$fri1959" 5000 5000
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]

  reset
  wk_rows "$fri2000" 5000 5000
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick
}

@test "TK-05b: Sunday 12:00 and 23:59 are not judged, Monday 00:00 UTC is" {
  weekend_times
  wk_rows "$sun1200" 5000 5000
  tick_run
  [ "$(atst_test_push_count)" -eq 0 ]
  reset
  wk_rows "$sun2359" 5000 5000
  tick_run
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick
  reset
  wk_rows "$mon0000" 5000 5000
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TK-06 (T5): ATST_TICK_WEEKEND_SKIP=0 judges the weekend; any other value (00, abc, empty, 1) does not" {
  local v
  weekend_times
  wk_rows "$sat" 5000 5000
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  for v in 00 abc '' 1; do
    reset
    wk_rows "$sat" 5000 5000
    atst_test_set_config ATST_TICK_WEEKEND_SKIP "$v"
    tick_run
    [ "$status" -eq 0 ] || { echo "v=$v status=$status"; false; }
    [ "$(atst_test_push_count)" -eq 0 ] || { echo "v=$v pushed"; false; }
    [ -z "$output" ] || { echo "v=$v output=$output"; false; }
  done
}

@test "TK-07 (T6): no csv / no complete line / no line outside the window / a stopped csv: not judged" {
  # (a) no csv
  tick_run
  [ "$status" -eq 0 ]; [ -z "$output" ]; [ "$(atst_test_push_count)" -eq 0 ]; no_tick
  # (b) only broken lines
  reset
  mkdir -p "$(dirname "$C")"
  printf 'x,100,1,1,1,1,1,U\n' >> "$C"
  printf '\n' >> "$C"
  printf '17' >> "$C"
  tick_run
  [ "$status" -eq 0 ]; [ -z "$output" ]; [ "$(atst_test_push_count)" -eq 0 ]; no_tick
  # (c) the window is not full yet
  reset
  row 300 100; row 0 100
  tick_run
  [ "$status" -eq 0 ]; [ -z "$output" ]; [ "$(atst_test_push_count)" -eq 0 ]; no_tick
  # (d) the last line is older than ATST_MONITORING_THRESHOLD (180)
  reset
  row 1000 100; row 900 100; row 400 100
  tick_run
  [ "$status" -eq 0 ]; [ -z "$output" ]; [ "$(atst_test_push_count)" -eq 0 ]; no_tick
  # (e) not judged does not recover an alert
  reset
  mkdir -p "$HOME/.atst"
  printf 'TICK_A_MT4,1,%s\n' "$(date +%s)" > "$ST"
  row 300 100; row 0 100
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TK-08 (T7): lines with field 2 = 0 are ignored" {
  row 700; row 300; row 0
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick
  reset
  span 900 300 100; row 200; span 140 0 100
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TK-09 (T8): without ATST_TICK_THRESHOLD the window is 600 s (590 / 610 around it); abc and 30 use 600 with one stderr line" {
  drop_threshold
  # (a) changed 590 s ago: inside the window
  x_rows 590
  run env -u ATST_TICK_THRESHOLD bash "$S" A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  # (b) changed 610 s ago: outside
  reset
  x_rows 610
  run env -u ATST_TICK_THRESHOLD bash "$S" A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -cF "$FIRE600" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  # (c) abc
  reset
  x_rows 610
  atst_test_set_config ATST_TICK_THRESHOLD abc
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -cF "$FIRE600" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$output" = "$BADT" ]
  # (d) 30
  reset
  drop_threshold
  atst_test_set_config ATST_TICK_THRESHOLD 30
  x_rows 610
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -cF "$FIRE600" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$output" = "$BADT" ]
}

@test "TK-12: the key is the folder name with spaces as _" {
  atst_test_make_mt 'A B' MT4
  span 700 0 100 'A B'
  run bash "$S" 'A B'
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^TICK_A_B,1,' "$ST")" -eq 1 ]
  grep -qF '【発生】A B の価格データ（ティック）' "$ATST_TEST_CURL_LOG"
}

@test "TK-13: an invalid ATST_TICK_THRESHOLD is one stderr line per run, with two MetaTraders or none found" {
  atst_test_make_mt B_MT4 MT4
  x_rows 610
  x_rows 610 B_MT4
  atst_test_set_config ATST_TICK_THRESHOLD abc
  run bash "$S" A_MT4 B_MT4
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$output" = "$BADT" ]
  run bash "$S" NOSUCH
  [ "$status" -eq 0 ]
  [ "$output" = "$BADT" ]
}

@test "TK-14: each MetaTrader has its own key" {
  atst_test_make_mt B_MT4 MT4
  span 700 0 100
  span 700 120 100 B_MT4
  span 100 0 101 B_MT4
  run bash "$S" A_MT4 B_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^TICK_A_MT4,1,' "$ST")" -eq 1 ]
  [ "$(grep -c '^TICK_B_MT4,' "$ST")" -eq 0 ]
}

@test "TK-15: a line newer than the last complete line (out of order) is not in the window" {
  span 900 60 100; row -100 555; row 0 100
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TK-16: a last line in the future (the Wine clock ahead) is still judged" {
  span 700 -60 100
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TK-17: ATST_MONITORING_THRESHOLD gates the judgement; invalid values use 180 silently" {
  # (a) 170 s old: judged
  span 900 170 100
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  # (b) 200 s old: not judged
  reset
  span 900 200 100
  tick_run
  [ "$(atst_test_push_count)" -eq 0 ]
  # (c) abc -> 180
  reset
  atst_test_set_config ATST_MONITORING_THRESHOLD abc
  span 900 200 100
  tick_run
  [ "$(atst_test_push_count)" -eq 0 ]
  [ -z "$output" ]
  # (d) 11 digits -> 180
  reset
  atst_test_set_config ATST_MONITORING_THRESHOLD 99999999999
  span 900 200 100
  tick_run
  [ "$(atst_test_push_count)" -eq 0 ]
  [ -z "$output" ]
  # (e) 1000 is read from the config
  reset
  atst_test_set_config ATST_MONITORING_THRESHOLD 1000
  span 1500 500 100
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "TK-18: a stopped csv is reported by MONITORING_ only, not twice" {
  row 900 100; row 600 100; row 500 100
  run bash "$BATS_TEST_DIRNAME/../check_monitoring.sh" A_MT4
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -c '^MONITORING_A_MT4,1,' "$ST")" -eq 1 ]
  no_tick
  ! grep -qF '価格データ（ティック）' "$ATST_TEST_CURL_LOG"
}

@test "TK-19: an alert going into the weekend stays (no recovery there) and recovers on Monday" {
  weekend_times
  wk_rows "$fri1959" 5000 5000
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  wk_rows "$sat" 6000 6001
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  wk_rows "$mon0000" 7000 7001
  tick_run
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(grep -cF "$REC" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(state 0)" -eq 1 ]
}

@test "TK-20a: TICK_ still 1 after 31 minutes is reminded once (#141)" {
  local e
  mkdir -p "$HOME/.atst"
  e=$(( $(date +%s) - 1860 ))
  printf 'TICK_A_MT4,1,%s\n' "$e" > "$ST"
  span 700 0 100
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '【継続中 30 分】' "$ATST_TEST_CURL_LOG"
  grep -qF 'A_MT4 の価格データ（ティック）' "$ATST_TEST_CURL_LOG"
  [ "$(grep -c "^TICK_A_MT4,1,$e,1$" "$ST")" -eq 1 ]
}

@test "TK-20b: no reminder on the weekend (not judged), the line is unchanged" {
  local e
  weekend_times
  mkdir -p "$HOME/.atst"
  e=$(( $(date +%s) - 1860 ))
  printf 'TICK_A_MT4,1,%s\n' "$e" > "$ST"
  wk_rows "$sat" 5000 5000
  cp "$ST" "$ST.bak"
  tick_run
  [ "$(atst_test_push_count)" -eq 0 ]
  cmp "$ST" "$ST.bak"
}

@test "TK-21: short lines, a non-number or 0-led or signed field 2 and a half-written line are not complete" {
  local n
  n=$(date +%s)
  span 900 0 100
  printf '%s,101,1,1\n' "$n" >> "$C"
  printf '%s,abc,1,1,1,1,1,U\n' "$n" >> "$C"
  printf '%s,0101,1,1,1,1,1,U\n' "$n" >> "$C"
  printf '%s,-101,1,1,1,1,1,U\n' "$n" >> "$C"
  printf '%s' "${n:0:5}" >> "$C"
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TK-22: a name matching no MetaTrader does nothing" {
  run bash "$S" NOSUCH
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$ST" ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "TK-23: 60 and 86400 are taken; 59 86401 060 +600 -600 empty and a newline use 600 with one line" {
  local v
  drop_threshold
  atst_test_set_config ATST_TICK_THRESHOLD 60
  span 900 0 100
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF 'が 1 分以上' "$ATST_TEST_CURL_LOG"
  [ -z "$output" ]

  reset
  drop_threshold
  atst_test_set_config ATST_TICK_THRESHOLD 86400
  span 90000 0 100
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF 'が 1440 分以上' "$ATST_TEST_CURL_LOG"
  [ -z "$output" ]

  for v in 59 86401 060 +600 -600 '' $'6\n00'; do
    reset
    drop_threshold
    atst_test_set_config ATST_TICK_THRESHOLD "$v"
    x_rows 610
    tick_run
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "v=$v pushed=$(atst_test_push_count)"; false; }
    grep -qF 'が 10 分以上' "$ATST_TEST_CURL_LOG" || { echo "v=$v not 600"; false; }
    [ "$output" = "$BADT" ] || { echo "v=$v output=$output"; false; }
  done
}

@test "TK-24: back after a stop of T seconds or more, one new line: not judged (#137 B1)" {
  span 2400 1200 100
  row 10 200
  tick_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick
}

@test "TK-25: back after a stop, T seconds of rows with field 2 unchanged: judged and fired" {
  span 2400 1200 100
  span 700 0 200
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TK-26: a gap of ATST_MONITORING_THRESHOLD seconds or more inside the window: not judged; a larger threshold judges it" {
  span 900 400 100
  span 200 0 100
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick
  # the same gap (200 s) is under 1000
  atst_test_set_config ATST_MONITORING_THRESHOLD 1000
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}

@test "TK-27: without any ATST_TICK_WEEKEND_SKIP line (the default 1) Saturday is not judged" {
  weekend_times
  sed -i '/^ATST_TICK_WEEKEND_SKIP=/d' "$HOME/.atst/config"
  ! grep -q 'ATST_TICK_WEEKEND_SKIP' "$HOME/.atst/config"
  wk_rows "$sat" 5000 5000
  run env -u ATST_TICK_WEEKEND_SKIP bash "$S" A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick
}

@test "TH-04: atst_test_make_monitoring_csv with 5 arguments: field 2 is 0 and field 6 is 12" {
  atst_test_make_monitoring_csv A_MT4 0 1.5 2 0.01
  [[ "$(tail -n 1 "$C")" =~ ^[0-9]+,0,1\.5,1\.5,2,12,0\.01,USDJPY$ ]]
}

@test "TH-05: with 6 arguments field 2 is still 0" {
  atst_test_make_monitoring_csv A_MT4 0 1.5 2 0.01 34
  [[ "$(tail -n 1 "$C")" =~ ^[0-9]+,0,1\.5,1\.5,2,34,0\.01,USDJPY$ ]]
}

@test "TH-06: the 7th argument is field 2" {
  atst_test_make_monitoring_csv A_MT4 0 1.5 2 0.01 12 1700000000
  [[ "$(tail -n 1 "$C")" =~ ^[0-9]+,1700000000,1\.5,1\.5,2,12,0\.01,USDJPY$ ]]
}

@test "TH-07: an empty 7th argument gives 0" {
  atst_test_make_monitoring_csv A_MT4 0 1.5 2 0.01 12 ''
  [[ "$(tail -n 1 "$C")" =~ ^[0-9]+,0, ]]
}

@test "TH-08: 4 or 9 arguments return 1 and add no line" {
  local n0
  atst_test_make_monitoring_csv A_MT4 0 1.5 2 0.01
  n0=$(wc -l < "$C")
  run atst_test_make_monitoring_csv A_MT4 0 1.5 2
  [ "$status" -eq 1 ]
  run atst_test_make_monitoring_csv A_MT4 0 1.5 2 0.01 12 1 x y
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$C")" -eq "$n0" ]
}

@test "TH-09: the 8th argument appends fields 9 and on (14 fields); an empty one gives 8 fields (#158)" {
  atst_test_make_monitoring_csv A_MT4 0 1.5 2 0.01 12 '' '1,1,1,1,0,0.00'
  [[ "$(tail -n 1 "$C")" =~ ^[0-9]+,0,1\.5,1\.5,2,12,0\.01,USDJPY,1,1,1,1,0,0\.00$ ]]
  [ "$(tail -n 1 "$C" | awk -F, '{print NF}')" -eq 14 ]
  atst_test_make_monitoring_csv A_MT4 0 1.5 2 0.01 12 '' ''
  [[ "$(tail -n 1 "$C")" =~ ^[0-9]+,0,1\.5,1\.5,2,12,0\.01,USDJPY$ ]]
}

# span14 <from_ago> <to_ago> <time_server> [<fields 9..14>]: span with the 14-field lines of the new EA (#158).
span14() {
  local n
  n=$(date +%s)
  awk -v a=$(( n - $1 )) -v b=$(( n - $2 )) -v v="$3" -v x="${4:-1,1,1,1,0,0.00}" 'BEGIN {
    for (t = a; t < b; t += 60) printf "%.0f,%s,150.0,150.0,10,12,0.01,USDJPY,%s\n", t, v, x
    printf "%.0f,%s,150.0,150.0,10,12,0.01,USDJPY,%s\n", b, v, x
  }' >> "$C"
}

@test "TK-28: 14-field lines (#158) are judged as before; mixed 8- and 14-field lines too" {
  # (a) field 2 unchanged in 14-field lines: fired
  mkdir -p "$(dirname "$C")"
  span14 700 0 100
  tick_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -cF "$FIRE600" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  # (b) field 2 changes in 14-field lines: nothing
  reset
  mkdir -p "$(dirname "$C")"
  span14 700 200 100; span14 100 0 101
  tick_run
  [ "$(atst_test_push_count)" -eq 0 ]
  no_tick
  # (c) 8-field lines before, 14-field lines after, field 2 unchanged: fired
  reset
  span 900 400 100
  span14 340 0 100
  tick_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
}
