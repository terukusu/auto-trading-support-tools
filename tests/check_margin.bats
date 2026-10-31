#!/usr/bin/env bats
# check_margin.sh (#177): MARGIN_<MT> fires when the last complete line of the monitoring csv (the last
# 20 lines, 14 fields or more, field 13 an integer and field 14 "digits.digits") has positions (field 13
# >= 1) and a margin level (field 14) below ATST_THRESHOLD_MARGIN_LOWER (L, default 200), and recovers at
# ATST_THRESHOLD_MARGIN_UPPER (U, default 300) or more, or when no position uses margin (field 13 = 0 or
# field 14 = 0). L <= field 14 < U keeps the state. L = 0 turns it off (an alert is closed once). Not
# judged: no csv / no complete line / a stopped csv (ATST_MONITORING_THRESHOLD). No weekend gate.
# Rows are made with atst_test_make_monitoring_csv (8th argument = fields 9 to 14).
# CM-xx are the IDs of the verification items (V-01 to V-25 of the plan).

load test_helper

FIRE='【発生】A_MT4 の証拠金維持率が 200% を下回りました: 150.00%（建玉 2 件。MT4 は待機注文を含みます）。このまま下がるとロスカット（強制決済）になります。'
REC_U='【復帰】A_MT4 の証拠金維持率が 300% 以上に戻りました: 300.00%。'
REC_OFF='【復帰】A_MT4 の証拠金維持率の監視を終了しました (ATST_THRESHOLD_MARGIN_LOWER が 0 です)。'
BADL='check_margin.sh: ATST_THRESHOLD_MARGIN_LOWER is not an integer from 0 to 999999; using 200'
BADU='check_margin.sh: ATST_THRESHOLD_MARGIN_UPPER is not an integer from 1 to 999999; using 300'
ADJ='check_margin.sh: ATST_THRESHOLD_MARGIN_UPPER is not above ATST_THRESHOLD_MARGIN_LOWER; using ATST_THRESHOLD_MARGIN_LOWER for both'

setup() {
  atst_test_setup_sandbox
  atst_test_make_mt A_MT4 MT4
  S="$BATS_TEST_DIRNAME/../check_margin.sh"
  ST="$HOME/.atst/alert_status"
  C="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
}

teardown() {
  atst_test_teardown_sandbox
}

# not_in <grep -q arguments>: fails when grep finds it (a bare "! grep" in the middle of a test does not
# fail the test).
not_in() {
  ! grep -q "$@"
}

cm_run() {
  run bash "$S" A_MT4
}

# row <c13> <c14> [<secs_ago> [<mt>]]: one 14-field line (fields 9 to 12 all 1), 10 seconds old by default.
row() {
  atst_test_make_monitoring_csv "${4:-A_MT4}" "${3:-10}" 150.0 10 0.01 12 100 "1,1,1,1,$1,$2"
}

# row8 [<secs_ago>]: one 8-field line of an old EA.
row8() {
  atst_test_make_monitoring_csv A_MT4 "${1:-10}" 150.0 10 0.01 12 100
}

# state <0|1>: how many MARGIN_A_MT4 lines have that value.
state() {
  grep -c "^MARGIN_A_MT4,$1," "$ST" 2>/dev/null || true
}

no_margin() {
  [ ! -e "$ST" ] || ! grep -q '^MARGIN_' "$ST"
}

reset() {
  rm -f "$C" "$ST" "$ATST_TEST_CURL_LOG"
}

# The config from the template with both margin lines removed.
drop_margin() {
  mkdir -p "$HOME/.atst"
  [ -e "$HOME/.atst/config" ] || cp "$BATS_TEST_DIRNAME/../templates/config" "$HOME/.atst/config"
  sed -i '/^ATST_THRESHOLD_MARGIN_\(LOWER\|UPPER\)=/d' "$HOME/.atst/config"
}

# fire_state: MARGIN_A_MT4 already fired (no push recorded).
fire_state() {
  mkdir -p "$HOME/.atst"
  printf 'MARGIN_A_MT4,1,%s\n' "$(( $(date +%s) - 60 ))" >> "$ST"
}

@test "CM-01: executable; no argument prints the usage (2 lines) on stderr only and exits 1, before the settings" {
  test -x "$S"
  atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER abc
  run bash "$S"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = 'Usage: check_margin.sh <MetaTrader Name1> <MetaTrader Name2> ...' ]
  [[ "$output" != *ATST_THRESHOLD_MARGIN* ]]
  run bash -c 'bash "$1" 2>/dev/null' _ "$S"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "CM-02: the key is the folder name with spaces as _; each MetaTrader has its own key; an unknown name does nothing" {
  atst_test_make_mt 'A B' MT4
  row 2 150.00
  row 2 150.00 10 'A B'
  run bash "$S" 'A B' A_MT4 NOPE
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 2 ]
  [ "$(grep -c '^MARGIN_A_B,1,' "$ST")" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  [ "$(grep -c '^MARGIN_' "$ST")" -eq 2 ]
  run bash "$S" NOPE
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 2 ]
}

@test "CM-03 (AC-2): 2 positions at 150.00%: one 【発生】, and only once; nothing on stdout" {
  row 2 150.00
  cm_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(grep -cF "$FIRE" "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  run bash -c 'bash "$1" A_MT4 2>/dev/null' _ "$S"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "CM-04 (AC-3): after the alert 250.00 keeps the state, 300.00 recovers" {
  row 2 150.00
  cm_run
  [ "$(atst_test_push_count)" -eq 1 ]
  row 2 250.00
  cm_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  row 2 300.00
  cm_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF "$REC_U" "$ATST_TEST_CURL_LOG"
  [ "$(state 0)" -eq 1 ]
}

@test "CM-05 (AC-3): without an alert 250.00 and 300.00 send nothing and leave no state" {
  row 2 250.00
  cm_run
  [ "$status" -eq 0 ]
  row 2 300.00
  cm_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_margin
}

@test "CM-06 (AC-4): after the alert 0 positions and 0.00 recover as no position using margin" {
  row 2 150.00
  cm_run
  row 0 0.00
  cm_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF '【復帰】A_MT4 に証拠金を使う建玉が無くなりました（建玉 0 件）。決済かロスカットの可能性があるので約定通知を確認してください。' "$ATST_TEST_CURL_LOG"
  [ "$(state 0)" -eq 1 ]
}

@test "CM-07 (AC-4): 1 position at 0.00 (pending orders only) does not fire; after the alert it recovers" {
  row 1 0.00
  cm_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_margin
  reset
  row 2 150.00
  cm_run
  row 1 0.00
  cm_run
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF '【復帰】A_MT4 に証拠金を使う建玉が無くなりました（建玉 1 件）。' "$ATST_TEST_CURL_LOG"
  [ "$(state 0)" -eq 1 ]
}

@test "CM-08 (AC-5): no csv / 8 fields only / a half-written line only / field 14 abc / a stopped csv: not judged" {
  local c
  for c in nocsv old half abc stale; do
    reset
    case $c in
      old) row8 ;;
      half) atst_test_make_monitoring_csv A_MT4 10 150.0 10 0.01 12 100 '1,1,1,1,2,' ;;
      abc) row 2 abc ;;
      stale) row 2 150.00 200 ;;
    esac
    cm_run
    [ "$status" -eq 0 ] || { echo "c=$c status=$status"; false; }
    [ -z "$output" ] || { echo "c=$c output=$output"; false; }
    [ "$(atst_test_push_count)" -eq 0 ] || { echo "c=$c pushed"; false; }
    no_margin || { echo "c=$c state"; false; }
  done
}

@test "CM-09 (AC-5): the last complete line is used past 8-field and half-written lines; CRLF lines are read" {
  local c
  for c in old half crlf; do
    reset
    row 2 150.00
    case $c in
      old) row8 ;;
      half) atst_test_make_monitoring_csv A_MT4 5 150.0 10 0.01 12 100 '1,1,1,1,2,' ;;
      crlf) rm -f "$C"; printf '%s,0,150.0,150.0,10,12,0.01,USDJPY,1,1,1,1,2,150.00\r\n' "$(( $(date +%s) - 10 ))" > "$C" ;;
    esac
    cm_run
    [ "$status" -eq 0 ] || { echo "c=$c status=$status"; false; }
    [ "$(atst_test_push_count)" -eq 1 ] || { echo "c=$c pushed=$(atst_test_push_count)"; false; }
    grep -qF "$FIRE" "$ATST_TEST_CURL_LOG" || { echo "c=$c text"; false; }
  done
}

@test "CM-10 (AC-5): a Saturday 12:00 UTC line is judged (no weekend gate)" {
  local sat
  sat=$(( $(date -u -d 'last saturday 12:00' +%s) - 604800 ))
  [ "$(date -u -d "@$sat" '+%u %H%M')" = "6 1200" ]
  atst_test_set_config ATST_MONITORING_THRESHOLD 99999999
  mkdir -p "$(dirname "$C")"
  printf '%s,0,150.0,150.0,10,12,0.01,USDJPY,1,1,1,1,2,150.00\n' "$sat" > "$C"
  cm_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "$FIRE" "$ATST_TEST_CURL_LOG"
}

@test "CM-11 (AC-6): templates/config has both settings with comments; the reminder comment lists the margin level" {
  local t="$BATS_TEST_DIRNAME/../templates/config" l p
  [ "$(grep -c '^ATST_THRESHOLD_MARGIN_LOWER=200$' "$t")" -eq 1 ]
  [ "$(grep -c '^ATST_THRESHOLD_MARGIN_UPPER=300$' "$t")" -eq 1 ]
  grep -B1 '^ATST_THRESHOLD_MARGIN_LOWER=200$' "$t" | head -1 | grep -q '^#'
  grep -B1 '^ATST_THRESHOLD_MARGIN_UPPER=300$' "$t" | head -1 | grep -q '^#'
  l=$(grep -n '^ATST_THRESHOLD_MARGIN_LOWER=' "$t" | cut -d: -f1)
  p=$(grep -n '^ATST_THRESHOLD_PRICE_LOWER=50$' "$t" | cut -d: -f1)
  [ "$l" -gt "$p" ]
  grep -B4 '^ATST_ALERT_REMIND_MINUTES=' "$t" | grep -qF '証拠金維持率の低下'
}

@test "CM-12 (AC-6): without the two lines in the config 200 / 300 are used silently" {
  drop_margin
  not_in MARGIN "$HOME/.atst/config"
  row 2 150.00
  run env -u ATST_THRESHOLD_MARGIN_LOWER -u ATST_THRESHOLD_MARGIN_UPPER bash "$S" A_MT4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "$FIRE" "$ATST_TEST_CURL_LOG"
  row 2 299.99
  run env -u ATST_THRESHOLD_MARGIN_LOWER -u ATST_THRESHOLD_MARGIN_UPPER bash "$S" A_MT4
  [ "$(atst_test_push_count)" -eq 1 ]
  row 2 300.00
  run env -u ATST_THRESHOLD_MARGIN_LOWER -u ATST_THRESHOLD_MARGIN_UPPER bash "$S" A_MT4
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF "$REC_U" "$ATST_TEST_CURL_LOG"
}

@test "CM-13 (AC-6): LOWER=100 UPPER=150: 90.00 fires, 120.00 keeps the state, 150.00 recovers" {
  # The AC-6 example says "120.00 fires" with LOWER=100, which the judgement table (field 14 < L fires)
  # does not allow; the table wins, and 120.00 is the kept band here.
  atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER 100
  atst_test_set_config ATST_THRESHOLD_MARGIN_UPPER 150
  row 2 120.00
  cm_run
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  row 2 90.00
  cm_run
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '証拠金維持率が 100% を下回りました: 90.00%' "$ATST_TEST_CURL_LOG"
  row 2 120.00
  cm_run
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  row 2 150.00
  cm_run
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF '【復帰】A_MT4 の証拠金維持率が 150% 以上に戻りました: 150.00%。' "$ATST_TEST_CURL_LOG"
}

@test "CM-14 (AC-6): LOWER=0 does not judge; an alert is closed once, with or without a csv" {
  atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER 0
  row 2 50.00
  cm_run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  no_margin

  fire_state
  cm_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "$REC_OFF" "$ATST_TEST_CURL_LOG"
  [ "$(state 0)" -eq 1 ]
  cm_run
  [ "$(atst_test_push_count)" -eq 1 ]

  reset
  fire_state
  cm_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "$REC_OFF" "$ATST_TEST_CURL_LOG"
  [ "$(state 0)" -eq 1 ]
}

@test "CM-15 (AC-6): LOWER abc 1000000 0200 and empty use 200 / 300 with one stderr line (no value), two MetaTraders too" {
  local v
  atst_test_make_mt B_MT4 MT4
  for v in abc 1000000 0200 ''; do
    reset
    atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER "$v"
    row 2 150.00
    row 2 150.00 10 B_MT4
    run bash "$S" A_MT4 B_MT4
    [ "$status" -eq 0 ] || { echo "v=$v status=$status"; false; }
    [ "$output" = "$BADL" ] || { echo "v=$v output=$output"; false; }
    [ "$(atst_test_push_count)" -eq 2 ] || { echo "v=$v pushed=$(atst_test_push_count)"; false; }
    grep -qF "$FIRE" "$ATST_TEST_CURL_LOG" || { echo "v=$v not 200"; false; }
  done
}

@test "CM-16 (AC-6): UPPER=abc uses 300 with one stderr line" {
  atst_test_set_config ATST_THRESHOLD_MARGIN_UPPER abc
  row 2 150.00
  cm_run
  [ "$output" = "$BADU" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  row 2 299.99
  cm_run
  [ "$output" = "$BADU" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  row 2 300.00
  cm_run
  [ "$output" = "$BADU" ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF "$REC_U" "$ATST_TEST_CURL_LOG"
}

@test "CM-17 (AC-6): LOWER=500 without an UPPER line uses 500 for both with one stderr line" {
  drop_margin
  atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER 500
  row 2 450.00
  cm_run
  [ "$output" = "$ADJ" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '証拠金維持率が 500% を下回りました: 450.00%' "$ATST_TEST_CURL_LOG"
  row 2 499.99
  cm_run
  [ "$output" = "$ADJ" ]
  [ "$(atst_test_push_count)" -eq 1 ]
  [ "$(state 1)" -eq 1 ]
  row 2 500.00
  cm_run
  [ "$output" = "$ADJ" ]
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF '【復帰】A_MT4 の証拠金維持率が 500% 以上に戻りました: 500.00%。' "$ATST_TEST_CURL_LOG"
  [ "$(state 0)" -eq 1 ]
}

@test "CM-18 (AC-8): MARGIN_ still 1 after 31 minutes is reminded once with the level of that run" {
  local e
  mkdir -p "$HOME/.atst"
  e=$(( $(date +%s) - 1860 ))
  printf 'MARGIN_A_MT4,1,%s\n' "$e" > "$ST"
  row 2 140.00
  cm_run
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '【継続中 30 分】A_MT4 の証拠金維持率が 200% を下回りました: 140.00%' "$ATST_TEST_CURL_LOG"
  [ "$(grep -c "^MARGIN_A_MT4,1,$e,1$" "$ST")" -eq 1 ]
  cm_run
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "CM-19 (AC-8): self_heal.sh does not look at MARGIN; the heartbeat allow list has no MARGIN_" {
  not_in MARGIN "$BATS_TEST_DIRNAME/../self_heal.sh"
  grep -q 'PROCESS_|TARGET_|MONITORING_' "$BATS_TEST_DIRNAME/../heartbeat.sh"
  [ -z "$(grep 'PROCESS_|TARGET_|MONITORING_' "$BATS_TEST_DIRNAME/../heartbeat.sh" | grep MARGIN_)" ]
}

@test "CM-20 (AC-10): no path, token, price, symbol or field 13 as ,7, in the notices" {
  row 7 123.45
  cm_run
  [ "$(atst_test_push_count)" -eq 1 ]
  row 7 300.00
  cm_run
  [ "$(atst_test_push_count)" -eq 2 ]
  grep -qF '建玉 7 件' "$ATST_TEST_CURL_LOG"
  not_in -F "$ATST_TEST_SANDBOX" "$ATST_TEST_CURL_LOG"
  not_in Bearer "$ATST_TEST_CURL_LOG"
  not_in -F 150.0 "$ATST_TEST_CURL_LOG"
  not_in -F ',7,' "$ATST_TEST_CURL_LOG"
  not_in -F USDJPY "$ATST_TEST_CURL_LOG"
  not_in -F terminal_monitoring "$ATST_TEST_CURL_LOG"
}

@test "CM-21: atst_monitoring_last_row reads the last complete line of the last 20 lines" {
  local n i t c13 c14
  atst_test_source_common
  n=$(date +%s)
  mkdir -p "$(dirname "$C")"
  # (a) one complete line
  printf '%s,0,150.0,150.0,10,12,0.01,USDJPY,1,1,1,1,2,150.00\n' "$n" > "$C"
  run atst_monitoring_last_row "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "$n 2 150.00" ]
  # (b) a half-written line, an 8-field line and a blank line after it
  printf '%s,0,150.0,150.0,10,12,0.01,USDJPY,1,1,1,1,3,\n' "$n" >> "$C"
  printf '%s,0,150.0,150.0,10,12,0.01,USDJPY\n\n' "$n" >> "$C"
  run atst_monitoring_last_row "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "$n 2 150.00" ]
  # (c) 20 8-field lines after it: out of reach
  for i in $(seq 1 20); do
    printf '%s,0,150.0,150.0,10,12,0.01,USDJPY\n' "$n" >> "$C"
  done
  run atst_monitoring_last_row "$C"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # (d) values too long for arithmetic
  for i in "1234567890123|2|150.00" "$n|1234567890|150.00" "$n|2|1234567890123456.00"; do
    IFS='|' read -r t c13 c14 <<< "$i"
    printf '%s,0,150.0,150.0,10,12,0.01,USDJPY,1,1,1,1,%s,%s\n' "$t" "$c13" "$c14" > "$C"
    run atst_monitoring_last_row "$C"
    [ "$status" -eq 1 ] || { echo "i=$i status=$status"; false; }
    [ -z "$output" ] || { echo "i=$i output=$output"; false; }
  done
  # (e) no file, empty argument: nothing on stdout or stderr
  run atst_monitoring_last_row "$C.none"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run atst_monitoring_last_row ''
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "CM-22: LOWER=0 UPPER=abc gives the UPPER line only (no adjustment)" {
  atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER 0
  atst_test_set_config ATST_THRESHOLD_MARGIN_UPPER abc
  row 2 150.00
  cm_run
  [ "$status" -eq 0 ]
  [ "$output" = "$BADU" ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "CM-23: at most one line per setting however many MetaTraders; LOWER=500 UPPER=abc gives the UPPER line and the adjustment" {
  atst_test_make_mt B_MT4 MT4
  atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER abc
  atst_test_set_config ATST_THRESHOLD_MARGIN_UPPER abc
  row 2 150.00
  row 2 150.00 10 B_MT4
  run bash "$S" A_MT4 B_MT4
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$BADL" ]
  [ "${lines[1]}" = "$BADU" ]
  atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER 500
  run bash "$S" A_MT4 B_MT4
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$BADU" ]
  [ "${lines[1]}" = "$ADJ" ]
  atst_test_set_config ATST_THRESHOLD_MARGIN_LOWER abc0
  atst_test_set_config ATST_THRESHOLD_MARGIN_UPPER 0
  run bash "$S" A_MT4 B_MT4
  [ "${#lines[@]}" -eq 2 ]
}

@test "CM-24: field 13 is given as a plain number (002 -> 2)" {
  row 002 150.00
  cm_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '（建玉 2 件。' "$ATST_TEST_CURL_LOG"
  not_in -F '002' "$ATST_TEST_CURL_LOG"
}

@test "CM-25: 0.50 is a low level (not 0.00); a line in the future is judged" {
  row 1 0.50
  cm_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF '200% を下回りました: 0.50%（建玉 1 件。' "$ATST_TEST_CURL_LOG"
  reset
  row 2 150.00 -120
  cm_run
  [ "$(atst_test_push_count)" -eq 1 ]
  grep -qF "$FIRE" "$ATST_TEST_CURL_LOG"
}
