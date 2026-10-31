#!/usr/bin/env bats
# The positions note (#177): the 【発生】 of PROCESS_ / MONITORING_ / TICK_ / TRADE_ (and the 【継続中】 made
# from it) end with " 建玉 N 件（M 分前の監視データ。MT4 は待機注文を含みます）" when field 13 of the last
# complete line of the monitoring csv (atst_positions_note in lib/atst_mt.sh) is 1 or more. Nothing is
# added for 0 positions, an old EA (8 fields), no csv or the "no data" path of MONITORING_; the 【復帰】
# messages are unchanged. Runs of 14-field rows every 60 seconds are made with span (oldest first).
# The weekend gates of check_tick.sh / check_trade_ready.sh are off in setup so the tests do not depend
# on the day they run. PN-xx are the IDs of the verification items (V-30 to V-39 of the plan).

load test_helper

NOTE3_3='建玉 3 件（3 分前の監視データ。MT4 は待機注文を含みます）'
NOTE3_1='建玉 3 件（1 分前の監視データ。MT4 は待機注文を含みます）'

setup() {
  atst_test_setup_sandbox
  atst_test_make_mt A_MT4 MT4
  R="$BATS_TEST_DIRNAME/.."
  ST="$HOME/.atst/alert_status"
  C="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
  atst_test_set_config ATST_TICK_WEEKEND_SKIP 0
  atst_test_set_config ATST_TRADE_READY_WEEKEND_SKIP 0
}

teardown() {
  atst_test_teardown_sandbox
}

# not_in <grep -q arguments>: fails when grep finds it (a bare "! grep" in the middle of a test does not
# fail the test).
not_in() {
  ! grep -q "$@"
}

# row <secs_ago> <c9..c14>: one line, field 2 = 100.
row() {
  atst_test_make_monitoring_csv A_MT4 "$1" 150.0 10 0.01 12 100 "$2"
}

# span <from_ago> <to_ago> <c2> <c9..c14>: rows every 60 seconds from <from_ago> and one at <to_ago>.
# <c2> "t" makes field 2 = field 1 (a moving tick).
span() {
  local n
  n=$(date +%s)
  mkdir -p "$(dirname "$C")"
  awk -v a=$(( n - $1 )) -v b=$(( n - $2 )) -v c2="$3" -v x="$4" '
    function p(t) { printf "%.0f,%s,150.0,150.0,10,12,0.01,USDJPY,%s\n", t, (c2 == "t" ? sprintf("%.0f", t) : c2), x }
    BEGIN { for (t = a; t < b; t += 60) p(t); p(b) }' >> "$C"
}

# set_state <key> <secs_ago>: the key already fired <secs_ago> seconds ago.
set_state() {
  mkdir -p "$HOME/.atst"
  printf '%s,1,%s\n' "$1" "$(( $(date +%s) - $2 ))" >> "$ST"
}

reset() {
  rm -f "$C" "$ST" "$ATST_TEST_CURL_LOG"
}

no_leak() {
  not_in -F "$ATST_TEST_SANDBOX" "$ATST_TEST_CURL_LOG"
  not_in Bearer "$ATST_TEST_CURL_LOG"
  not_in -F 150.0 "$ATST_TEST_CURL_LOG"
  not_in -F USDJPY "$ATST_TEST_CURL_LOG"
  not_in -F terminal_monitoring "$ATST_TEST_CURL_LOG"
  not_in -F 123.45 "$ATST_TEST_CURL_LOG"
  not_in -F ',7,' "$ATST_TEST_CURL_LOG"
}

@test "PN-01: atst_positions_note prints the count and the age of the last complete line, or nothing" {
  atst_test_source_common
  row 200 1,1,1,1,3,123.45
  run atst_positions_note A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "$NOTE3_3" ]
  rm -f "$C"
  row 200 1,1,1,1,003,123.45
  run atst_positions_note A_MT4
  [ "$output" = "$NOTE3_3" ]
  rm -f "$C"
  row -120 1,1,1,1,3,123.45
  run atst_positions_note A_MT4
  [ "$output" = '建玉 3 件（0 分前の監視データ。MT4 は待機注文を含みます）' ]

  rm -f "$C"
  row 200 1,1,1,1,0,0.00
  run atst_positions_note A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$C"
  atst_test_make_monitoring_csv A_MT4 200 150.0 10 0.01 12 100
  run atst_positions_note A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$C"
  run atst_positions_note A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  row 200 1,1,1,1,3,123.45
  run atst_positions_note NOPE
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run atst_positions_note ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "PN-02: check_process.sh: the 【発生】 ends with the note" {
  row 200 1,1,1,1,3,123.45
  run bash "$R/check_process.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "【発生】MetaTraderプロセスが動作していません: A_MT4 $NOTE3_3\"" "$ATST_TEST_CURL_LOG"
}

@test "PN-03: check_monitoring.sh (stale data): the 【発生】 ends with the note" {
  row 200 1,1,1,1,3,123.45
  run bash "$R/check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "更新されていません。 EAが動いていない可能性が有ります。 $NOTE3_3\"" "$ATST_TEST_CURL_LOG"
}

@test "PN-04: check_tick.sh: the 【発生】 ends with the note" {
  span 900 60 100 1,1,1,1,3,123.45
  run bash "$R/check_tick.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "この間は自動売買が動きません。 $NOTE3_1\"" "$ATST_TEST_CURL_LOG"
}

@test "PN-05: check_trade_ready.sh: the 【発生】 ends with the note" {
  span 700 60 100 0,1,1,1,3,123.45
  run bash "$R/check_trade_ready.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "（MetaTrader は動いていて監視データは更新されています）。 $NOTE3_1\"" "$ATST_TEST_CURL_LOG"
}

@test "PN-06: 0 positions, 8-field lines only or no csv: the 【発生】 of check_process.sh is unchanged" {
  local c
  for c in zero old nocsv; do
    reset
    case $c in
      zero) row 200 1,1,1,1,0,0.00 ;;
      old) atst_test_make_monitoring_csv A_MT4 200 150.0 10 0.01 12 100 ;;
    esac
    run bash "$R/check_process.sh" A_MT4
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "c=$c pushed"; false; }
    grep -qF '【発生】MetaTraderプロセスが動作していません: A_MT4"' "$ATST_TEST_CURL_LOG" || { echo "c=$c text"; false; }
    ! grep -qF '建玉' "$ATST_TEST_CURL_LOG" || { echo "c=$c note"; false; }
  done
}

@test "PN-07: the 【復帰】 of MONITORING_, TICK_ and TRADE_ is unchanged" {
  set_state MONITORING_A_MT4 600
  set_state TICK_A_MT4 600
  set_state TRADE_A_MT4 600
  span 900 0 t 1,1,1,1,3,123.45
  run bash "$R/check_monitoring.sh" A_MT4
  [ "$status" -eq 0 ]
  run bash "$R/check_tick.sh" A_MT4
  [ "$status" -eq 0 ]
  run bash "$R/check_trade_ready.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 3 ]
  grep -qF '【復帰】A_MT4 のモニタリングデータの更新が再開しました。"' "$ATST_TEST_CURL_LOG"
  grep -qF '【復帰】A_MT4 の価格データ（ティック）の更新が再開しました。"' "$ATST_TEST_CURL_LOG"
  grep -qF '【復帰】A_MT4 が取引できる状態に戻りました。"' "$ATST_TEST_CURL_LOG"
  not_in -F '建玉' "$ATST_TEST_CURL_LOG"
}

@test "PN-08: the 【継続中】 of PROCESS_ carries the note" {
  set_state PROCESS_A_MT4 1860
  row 200 1,1,1,1,3,123.45
  run bash "$R/check_process.sh" A_MT4
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "【継続中 30 分】MetaTraderプロセスが動作していません: A_MT4 $NOTE3_3\"" "$ATST_TEST_CURL_LOG"
}

@test "PN-09: one helper in lib/; no check script but check_trade_ready.sh has its own NF >= 14 awk" {
  local f
  [ "$(cd "$R" && grep -l 'NF >= 14' check_*.sh)" = check_trade_ready.sh ]
  for f in check_process.sh check_monitoring.sh check_tick.sh check_trade_ready.sh; do
    grep -q 'atst_positions_note "\$target_name"' "$R/$f" || { echo "f=$f"; false; }
  done
  [ "$(grep -c '^function atst_monitoring_last_row()' "$R/lib/atst_mt.sh")" -eq 1 ]
  [ "$(grep -c '^function atst_positions_note()' "$R/lib/atst_mt.sh")" -eq 1 ]
}

@test "PN-10: no path, token, price, symbol, field 14 or ,7, in the 【発生】 of TICK_ and TRADE_" {
  span 900 60 100 0,1,1,1,7,123.45
  run bash "$R/check_tick.sh" A_MT4
  run bash "$R/check_trade_ready.sh" A_MT4
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(grep -cF '建玉 7 件' "$ATST_TEST_CURL_LOG")" -eq 2 ]
  no_leak
}

@test "PN-10b: no path, token, price, symbol, field 14 or ,7, in the 【発生】 of PROCESS_ and MONITORING_" {
  row 200 1,1,1,1,7,123.45
  run bash "$R/check_process.sh" A_MT4
  run bash "$R/check_monitoring.sh" A_MT4
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(grep -cF '建玉 7 件' "$ATST_TEST_CURL_LOG")" -eq 2 ]
  no_leak
}
