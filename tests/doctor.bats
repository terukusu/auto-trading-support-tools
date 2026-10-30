#!/usr/bin/env bats
# doctor.sh (#132): the read-only self check on the sandbox. wine and crontab are stubs in
# $ATST_TEST_SANDBOX/bin put first on PATH; doctor.sh runs as a subprocess and is never sourced.

load test_helper

# AppData hash of the fake MetaTrader. It contains none of the strings the tests look for in the output
# (1234, 9876, cdef).
DOCTOR_HASH=A1B2C3D4E5F60718293A4B5C6D7E8F90

setup() {
  atst_test_setup_sandbox
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
  doctor_make_ok_state
}

teardown() {
  atst_test_teardown_sandbox
}

# Only acts inside the sandbox.
doctor_in_sandbox() {
  [ -n "${ATST_TEST_SANDBOX:-}" ] && [ "$HOME" = "$ATST_TEST_SANDBOX/home" ]
}

# The AppData data folder of A_MT4 (the layout made by atst_test_make_mt with a hash).
doctor_data_dir() {
  printf '%s' "$WINEPREFIX/drive_c/users/tester/AppData/Roaming/MetaQuotes/Terminal/$DOCTOR_HASH"
}

# doctor_make_csv <secs_ago>
# atst_test_make_monitoring_csv writes to the install folder; doctor.sh reads the CSV of the data
# folder (atst_get_monitoring_csv_path), so the line is moved there.
doctor_make_csv() {
  local src dst

  doctor_in_sandbox || return 1
  atst_test_make_monitoring_csv A_MT4 "$1" 150.000 10 0.01 || return 1
  src="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
  dst="$(doctor_data_dir)/MQL4/Files/terminal_monitoring.csv"
  cat "$src" >> "$dst" && rm -f "$src"
}

# doctor_stub <name> <body>
# Writes the command <name> into $ATST_TEST_SANDBOX/bin.
doctor_stub() {
  doctor_in_sandbox || return 1
  mkdir -p "$ATST_TEST_SANDBOX/bin" || return 1
  printf '#!/bin/bash\n%s\n' "$2" > "$ATST_TEST_SANDBOX/bin/$1" || return 1
  chmod +x "$ATST_TEST_SANDBOX/bin/$1"
}

# The state where every item is OK (AC-5), except the heartbeat, which is -- (not set).
doctor_make_ok_state() {
  local ea_dir

  doctor_in_sandbox || return 1
  atst_test_make_mt A_MT4 MT4 "$DOCTOR_HASH" || return 1
  atst_test_set_config WINEPREFIX "$WINEPREFIX" || return 1
  atst_test_set_targets A_MT4 || return 1
  printf 'abcdefghijkl1234\n' > "$HOME/.atst/.line_token" || return 1
  printf 'U0123456789abcdef\n' > "$HOME/.atst/.line_id" || return 1
  chmod 600 "$HOME/.atst/.line_token" "$HOME/.atst/.line_id" || return 1
  ea_dir="$(doctor_data_dir)/MQL4/Experts"
  mkdir -p "$ea_dir" || return 1
  : > "$ea_dir/TerminalMonitoring.ex4" || return 1
  doctor_make_csv 10 || return 1
  atst_test_make_proc 123 - "$(printf 'HOME=%s\nWINEPREFIX=%s' "$HOME" "$WINEPREFIX")" \
    'C:\Program Files\A_MT4\terminal.exe' || return 1
  doctor_stub wine 'echo wine-10.0' || return 1
  doctor_stub crontab "[ \"\$1\" = -l ] || exit 1
cat $(printf '%q' "$ATST_TEST_SANDBOX/crontab.txt") 2>/dev/null || exit 1" || return 1
  printf '* * * * * check_all.sh\n' > "$ATST_TEST_SANDBOX/crontab.txt"
}

doctor_run() {
  run bash "$BATS_TEST_DIRNAME/../doctor.sh"
}

# doctor_line_of <regex>: the item lines whose label and value start with <regex>.
doctor_line_of() {
  printf '%s\n' "$output" | grep -E "^(OK|NG|--) $1"
}

# Count of output lines starting with "NG " (a plain *NG* match could hit the random sandbox path).
doctor_ng_count() {
  printf '%s\n' "$output" | grep -c '^NG '
}

@test "DR-1: every item is OK and the heartbeat is -- (AC-5)" {
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(doctor_ng_count)" -eq 0 ]
  [[ "${lines[${#lines[@]}-1]}" == "OK summary "* ]]
  [[ "${lines[${#lines[@]}-1]}" == *" ng=0 "* ]]
  [ -n "$(printf '%s\n' "$output" | grep '^-- heartbeat not set (recommended: run setup_heartbeat\.sh)$')" ]
  [ -z "$(printf '%s\n' "$output" | grep 'ATST_HEARTBEAT_URL not set')" ]
  [ -n "$(doctor_line_of 'wine --version wine-10\.0')" ]
  [ -n "$(doctor_line_of 'arch win64')" ]
  [ -n "$(doctor_line_of 'process A_MT4 pid=123')" ]
  [ -n "$(doctor_line_of 'csv A_MT4 last update')" ]
  [ -n "$(doctor_line_of 'crontab -l new format')" ]
}

@test "DR-2: WINEPREFIX missing from the config is NG with both prefixes (AC-6)" {
  doctor_in_sandbox
  sed -i '/^WINEPREFIX=/d' "$HOME/.atst/config"
  doctor_run
  [ "$status" -eq 1 ]
  line=$(printf '%s\n' "$output" | grep '^NG WINEPREFIX ')
  [ -n "$line" ]
  [[ "$line" == *"config=$WINEPREFIX "* ]]
  [[ "$line" == *"cron=~/.wine"* ]]
}

@test "DR-3: a prefix without system.reg makes arch NG (AC-6)" {
  rm "$WINEPREFIX/system.reg"
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG arch ')" ]
}

@test "DR-4: a failing wine makes the wine line NG (AC-6)" {
  doctor_stub wine 'exit 1'
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG wine --version ')" ]
}

@test "DR-5: only the last 4 characters of the token and nothing of the LINE ID are shown (AC-7)" {
  doctor_run
  [ "$status" -eq 0 ]
  [[ "$output" != *abcdefghijkl1234* ]]
  [[ "$output" == *"****1234"* ]]
  [[ "$output" != *U0123456789abcdef* ]]
  [[ "$output" != *cdef* ]]
  [ -n "$(printf '%s\n' "$output" | grep '^OK \.line_id mode 600$')" ]
}

@test "DR-6: a secret file with mode 644 is NG and shows no characters (AC-7)" {
  chmod 644 "$HOME/.atst/.line_token"
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG \.line_token mode 644')" ]
  [[ "$output" != *1234* ]]

  chmod 600 "$HOME/.atst/.line_token"
  chmod 644 "$HOME/.atst/.line_id"
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG \.line_id mode 644')" ]
  [[ "$output" != *cdef* ]]
}

@test "DR-7: the heartbeat URL is shown as its last 4 characters (AC-7)" {
  atst_test_set_config ATST_HEARTBEAT_URL "https://example.invalid/ping/abcd9876"
  doctor_run
  [ "$status" -eq 0 ]
  [[ "$output" == *9876* ]]
  [[ "$output" != *example.invalid* ]]
  [ -n "$(printf '%s\n' "$output" | grep '^OK heartbeat ATST_HEARTBEAT_URL=\*\*\*\*9876$')" ]
}

@test "DR-8: a target matching no MetaTrader is NG and the MetaTrader found is -- (AC-8)" {
  atst_test_set_targets NO_SUCH_MT
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG target NO_SUCH_MT ')" ]
  [ -n "$(printf '%s\n' "$output" | grep '^-- mt A_MT4 ')" ]
  # not counted twice: process / ea / csv of that target are --
  [ -n "$(printf '%s\n' "$output" | grep '^-- process NO_SUCH_MT ')" ]
}

@test "DR-9: an empty ATST_TARGETS is NG (AC-8)" {
  atst_test_set_targets
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG ATST_TARGETS ')" ]
  [ -n "$(printf '%s\n' "$output" | grep '^-- mt A_MT4 ')" ]
}

@test "DR-10: crontab forms: mixed / empty / comment only are NG, old only is OK (AC-9)" {
  printf '* * * * * check_all.sh\n* * * * * wrapper.sh "$TARGET" check_process.sh\n' > "$ATST_TEST_SANDBOX/crontab.txt"
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG crontab -l mixed')" ]

  : > "$ATST_TEST_SANDBOX/crontab.txt"
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG crontab -l ')" ]

  printf '# * * * * * check_all.sh\n' > "$ATST_TEST_SANDBOX/crontab.txt"
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG crontab -l ')" ]

  printf '* * * * * wrapper.sh "$TARGET" check_process.sh\n' > "$ATST_TEST_SANDBOX/crontab.txt"
  doctor_run
  [ "$status" -eq 0 ]
  line=$(printf '%s\n' "$output" | grep '^OK crontab -l ')
  [ -n "$line" ]
  [[ "$line" == *旧形式* ]]
}

@test "DR-11: a CSV older than the threshold is NG (AC-10)" {
  rm -f "$(doctor_data_dir)/MQL4/Files/terminal_monitoring.csv"
  doctor_make_csv 400
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG csv A_MT4 ')" ]
}

@test "DR-12: a missing monitoring EA is NG (AC-10)" {
  rm -f "$(doctor_data_dir)/MQL4/Experts/TerminalMonitoring.ex4"
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep '^NG ea A_MT4 not found')" ]
}

@test "DR-13: with many NG items nothing is sent and no file is written (AC-11)" {
  doctor_in_sandbox
  sed -i '/^WINEPREFIX=/d' "$HOME/.atst/config"
  chmod 644 "$HOME/.atst/.line_token"
  rm -f "$(doctor_data_dir)/MQL4/Files/terminal_monitoring.csv"
  doctor_make_csv 400
  printf '* * * * * check_all.sh\n* * * * * wrapper.sh "$TARGET" check_process.sh\n' > "$ATST_TEST_SANDBOX/crontab.txt"
  doctor_run
  [ "$status" -eq 1 ]

  atst_test_set_targets NO_SUCH_MT
  touch "$ATST_TEST_SANDBOX/marker"
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(doctor_ng_count)" -ge 4 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [ ! -s "$ATST_TEST_CURL_LOG" ]
  [ -z "$(find "$ATST_TEST_SANDBOX" -newer "$ATST_TEST_SANDBOX/marker" ! -path "$ATST_TEST_SANDBOX/marker")" ]
}

@test "DR-14: every line is an item or indented, and the home directory is shown as ~ (AC-12)" {
  printf '[2026-10-28 00:00:00] LINE send failed: http=500 script=check_x.sh\n  response: secret-body\n  message: secret-msg\n' \
    > "$HOME/.atst/line_error.log"
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -vcE '^((OK|NG|--) |  )')" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cE '^(OK|NG|--) ')" -ge 10 ]
  [[ "$output" != *"$HOME"* ]]
  [[ "$output" == *"~/.atst/"* ]]
  [[ "$output" == *"LINE send failed: http=500 script=check_x.sh"* ]]
  [[ "$output" != *secret-body* ]]
  [[ "$output" != *secret-msg* ]]

  # the same with NG items
  sed -i '/^WINEPREFIX=/d' "$HOME/.atst/config"
  chmod 644 "$HOME/.atst/.line_token"
  atst_test_set_targets NO_SUCH_MT
  : > "$ATST_TEST_SANDBOX/crontab.txt"
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -vcE '^((OK|NG|--) |  )')" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cE '^(OK|NG|--) ')" -ge 10 ]
  [[ "$output" != *"$HOME"* ]]
  [[ "$output" == *"~/.atst/"* ]]
}

@test "DR-15: an argument prints usage, exits 1 and does not read common.sh (AC-13)" {
  doctor_in_sandbox
  rm -rf "$HOME/.atst"
  run bash "$BATS_TEST_DIRNAME/../doctor.sh" foo
  [ "$status" -eq 1 ]
  [[ "$output" == *Usage:* ]]
  [ "$(printf '%s\n' "$output" | grep -cE '^(OK|NG|--) ')" -eq 0 ]
  [ ! -e "$HOME/.atst" ]
}

# The indented lines under item 11 (check_all.log, the last item before the summary).
cl_notes() {
  printf '%s\n' "$output" | awk '/^-- check_all\.log /{f=1;next} /^(OK|NG|--) /{f=0} f'
}

@test "DR-16: check_all.log: one item line with mode and last START, its tail without START lines, ~ for home (AC-10, AC-11)" {
  local D="$HOME/.atst/log" L="$HOME/.atst/log/check_all.log"
  mkdir -p "$D"
  printf '===== START 2026-10-29 06:30:00 pid=1 =====\n%s/.atst/check_all.lock: tail-line-4b2d\ncr-line\r-5e7a\n===== START 2026-10-29 06:30:00 pid=2 =====\n' "$HOME" > "$L"
  chmod 600 "$L"
  touch "$ATST_TEST_SANDBOX/marker"
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(doctor_ng_count)" -eq 0 ]
  [ "$(doctor_line_of 'check_all\.log ' | wc -l)" -eq 1 ]
  [[ "$(doctor_line_of 'check_all\.log ')" == "-- check_all.log "* ]]
  [[ "$(doctor_line_of 'check_all\.log ')" == *"~/.atst/log/check_all.log: mode 600, last START 2026-10-29 06:30:00, last 5 lines:"* ]]
  [[ "$(doctor_line_of 'check_all\.log ')" != *pid=* ]]
  [ "$(cl_notes | grep -cxF '  ~/.atst/check_all.lock: tail-line-4b2d')" -eq 1 ]
  [ "$(cl_notes | grep -cxF '  cr-line?-5e7a')" -eq 1 ]
  [ "$(cl_notes | grep -c '===== START')" -eq 0 ]
  [ "$(cl_notes | wc -l)" -eq 2 ]
  [[ "$output" != *"$HOME"* ]]
  [ "$(printf '%s\n' "$output" | grep -vcE '^((OK|NG|--) |  )')" -eq 0 ]
  [[ "$output" != *abcdefghijkl1234* ]]
  [[ "$output" != *U0123456789abcdef* ]]
  [[ "$output" != *cdef* ]]
  [[ "$output" != *Authorization* ]]
  [ -z "$(find "$ATST_TEST_SANDBOX" -newer "$ATST_TEST_SANDBOX/marker" ! -path "$ATST_TEST_SANDBOX/marker")" ]
  [[ "${lines[${#lines[@]}-1]}" == "OK summary "* ]]
  [[ "${lines[${#lines[@]}-1]}" == *" ng=0 "* ]]
}

@test "DR-17: no or an empty check_all.log is shown as none (AC-10)" {
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^-- check_all\.log none (~/\.atst/log/check_all\.log)$')" -eq 1 ]
  [ "$(cl_notes | wc -l)" -eq 0 ]
  [ "$(doctor_ng_count)" -eq 0 ]

  mkdir -p "$HOME/.atst/log"
  : > "$HOME/.atst/log/check_all.log"
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^-- check_all\.log none (~/\.atst/log/check_all\.log)$')" -eq 1 ]
  [ "$(cl_notes | wc -l)" -eq 0 ]
  [ "$(doctor_ng_count)" -eq 0 ]
}

@test "DR-18: a check_all.log without START lines shows last START none" {
  mkdir -p "$HOME/.atst/log"
  printf 'only-line-8a3f\n' > "$HOME/.atst/log/check_all.log"
  chmod 600 "$HOME/.atst/log/check_all.log"
  doctor_run
  [ "$status" -eq 0 ]
  [[ "$(doctor_line_of 'check_all\.log ')" == *"mode 600, last START none, last 5 lines:"* ]]
  [ "$(cl_notes)" = '  only-line-8a3f' ]
}

@test "DR-19: only the last 5 lines other than START are shown, with the date of the last START" {
  mkdir -p "$HOME/.atst/log"
  {
    echo '===== START 2026-10-29 06:30:00 pid=1 ====='
    for i in 1 2 3 4 5 6 7; do echo "body-$i-91d0"; done
    echo '===== START 2026-10-29 06:31:00 pid=2 ====='
  } > "$HOME/.atst/log/check_all.log"
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(cl_notes)" = "$(printf '  body-%s-91d0\n' 3 4 5 6 7)" ]
  [[ "$(doctor_line_of 'check_all\.log ')" == *"last START 2026-10-29 06:31:00,"* ]]
}

@test "DR-20: an unreadable check_all.log is still not NG and shows none of its lines" {
  [ "$EUID" -ne 0 ] || skip "root ignores permissions"
  mkdir -p "$HOME/.atst/log"
  printf '===== START 2026-10-29 06:30:00 pid=1 =====\ntail-line-4b2d\n' > "$HOME/.atst/log/check_all.log"
  chmod 000 "$HOME/.atst/log/check_all.log"
  doctor_run
  chmod 600 "$HOME/.atst/log/check_all.log"
  [ "$status" -eq 0 ]
  [ "$(doctor_ng_count)" -eq 0 ]
  [ "$(doctor_line_of 'check_all\.log ' | wc -l)" -eq 1 ]
  [[ "$(doctor_line_of 'check_all\.log ')" == *"mode 0, last START none,"* ]]
  [[ "$output" != *tail-line-4b2d* ]]
}

# DR-H20 to DR-H24 (#136): item 10 with ~/.atst/.heartbeat_url (setup_heartbeat.sh). The IDs are DR-20 to
# DR-24 of the #136 plan; "H" keeps them apart from DR-16 to DR-20 of #144.

# put_heartbeat_file <mode>: .heartbeat_url with a dummy URL ending in 2222.
put_heartbeat_file() {
  doctor_in_sandbox || return 1
  printf '%s\n' https://example.invalid/file/yyyy2222 > "$HOME/.atst/.heartbeat_url" || return 1
  chmod "$1" "$HOME/.atst/.heartbeat_url"
}

@test "DR-H20: .heartbeat_url (600) is OK and shown as its last 4 characters (AC19, AC21)" {
  put_heartbeat_file 600
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^OK heartbeat \.heartbeat_url=\*\*\*\*2222$')" -eq 1 ]
  [[ "$output" != *example.invalid* ]]
  [[ "$output" != *yyyy* ]]
}

@test "DR-H21: .heartbeat_url wins over the config URL (AC18, AC19)" {
  put_heartbeat_file 600
  atst_test_set_config ATST_HEARTBEAT_URL "https://example.invalid/ping/abcd9876"
  doctor_run
  [ "$(printf '%s\n' "$output" | grep -c '^OK heartbeat \.heartbeat_url=\*\*\*\*2222$')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^OK heartbeat ATST_HEARTBEAT_URL=')" -eq 0 ]
  [[ "$output" != *example.invalid* ]]
}

@test "DR-H22: .heartbeat_url not 600 (644, 400) is one NG, exit 1, no URL (AC19, AC21)" {
  local m
  for m in 644 400; do
    echo "case=$m"
    put_heartbeat_file "$m"
    doctor_run
    [ "$status" -eq 1 ]
    [ "$(printf '%s\n' "$output" | grep -c "^NG heartbeat mode $m (must be 600): ~/\.atst/\.heartbeat_url\$")" -eq 1 ]
    # one NG item (item 9 does not list .heartbeat_url) and the summary line
    [ "$(printf '%s\n' "$output" | grep '^NG ' | grep -vc '^NG summary ')" -eq 1 ]
    [[ "${lines[${#lines[@]}-1]}" == *" ng=1 "* ]]
    [[ "$output" != *example.invalid* ]]
    [[ "$output" != *yyyy2222* ]]
  done
}

@test "DR-H23: an empty .heartbeat_url (600) shows the config URL" {
  : > "$HOME/.atst/.heartbeat_url"
  chmod 600 "$HOME/.atst/.heartbeat_url"
  atst_test_set_config ATST_HEARTBEAT_URL "https://example.invalid/ping/abcd9876"
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^OK heartbeat ATST_HEARTBEAT_URL=\*\*\*\*9876$')" -eq 1 ]
}

@test "DR-H24: item 10 calls no curl and changes neither the file nor its mode" {
  local m c0
  for m in 600 644; do
    echo "case=$m"
    rm -f "$ATST_TEST_CURL_LOG"
    put_heartbeat_file "$m"
    c0=$(cksum < "$HOME/.atst/.heartbeat_url")
    doctor_run
    [ ! -s "$ATST_TEST_CURL_LOG" ]
    [ "$(cksum < "$HOME/.atst/.heartbeat_url")" = "$c0" ]
    [ "$(stat -c %a "$HOME/.atst/.heartbeat_url")" = "$m" ]
  done
}

# --- 12. auto_attach (ATST_AUTO_ATTACH_EA, #133). IDs DR-AA-n: DR-16..DR-20 are taken by check_all.log ---

# The auto_attach item line(s).
ini_line() {
  printf '%s\n' "$output" | grep '^\(OK\|NG\|--\) auto_attach '
}

aa_enable() {
  atst_test_set_config ATST_AUTO_ATTACH_EA 1 || return 1
  atst_test_set_config ATST_AUTO_ATTACH_SYMBOL "${1-EURUSD}" || return 1
  atst_test_set_config ATST_AUTO_ATTACH_PERIOD "${2-M5}"
}

# The ini mtctl.sh start writes for A_MT4 (EURUSD / M5), 600 in a 700 dir.
aa_make_ini() {
  local dir="$WINEPREFIX/drive_c/atst"
  atst_test_source_common || return 1
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  atst_startup_ini_content MT4 EURUSD M5 > "$dir/startup_a_mt4.ini" || return 1
  chmod 600 "$dir/startup_a_mt4.ini"
}

# aa_proc <argv>...: replaces the fake MetaTrader process 123.
aa_proc() {
  rm -rf "${ATST_PROC_ROOT:?}/123"
  atst_test_make_proc 123 - "$(printf 'HOME=%s\nWINEPREFIX=%s' "$HOME" "$WINEPREFIX")" "$@"
}

@test "DR-AA-1: ATST_AUTO_ATTACH_EA 0, no line or not 1 is -- (manual attach) and keeps exit 0" {
  local c
  for c in template noline yes; do
    case $c in
      noline) sed -i '/^ATST_AUTO_ATTACH_EA=/d' "$HOME/.atst/config" ;;
      yes) atst_test_set_config ATST_AUTO_ATTACH_EA yes ;;
    esac
    doctor_run
    [ "$status" -eq 0 ]
    [ "$(ini_line)" = "-- auto_attach A_MT4 ATST_AUTO_ATTACH_EA=0 (manual attach)" ]
    [[ ${lines[${#lines[@]}-1]} == "OK summary "*" ng=0 "* ]]
    [[ $(ini_line) != *yes* ]]
  done
}

@test "DR-AA-2: enabled without the ini is NG with a note, and doctor creates nothing" {
  aa_enable
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(ini_line)" = "NG auto_attach A_MT4 not found: $WINEPREFIX/drive_c/atst/startup_a_mt4.ini" ]
  printf '%s\n' "$output" | grep -A1 '^NG auto_attach ' | tail -n 1 | grep -q '^  .*mtctl.sh start'
  [ ! -e "$WINEPREFIX/drive_c/atst" ]
  [[ $output != *'.atst/startup_'* ]]
}

@test "DR-AA-3: enabled, ini ok and the bare C:\\atst\\... in the MT4 cmdline is OK; nothing secret, home as ~" {
  aa_enable
  aa_make_ini
  aa_proc 'C:\Program Files\A_MT4\terminal.exe' 'C:\atst\startup_a_mt4.ini'
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(ini_line)" = "OK auto_attach A_MT4 ini ok, ini argument passed (pid=123)" ]
  [ "$(printf '%s\n' "$output" | grep -vcE '^((OK|NG|--) |  )')" -eq 0 ]
  [[ $output != *"$HOME"* ]]
  [[ $output != *EURUSD* ]]
  [[ $output != *Expert=* ]]
  [[ $output != *Z:* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'no fresh CSV')" -eq 0 ]
}

@test "DR-AA-3b: the ini joined to argv[0] (one cmdline element) is OK and the process is found" {
  aa_enable
  aa_make_ini
  aa_proc 'C:\Program Files\A_MT4\terminal.exe C:\atst\startup_a_mt4.ini'
  doctor_run
  [ "$status" -eq 0 ]
  [ "$(ini_line)" = "OK auto_attach A_MT4 ini ok, ini argument passed (pid=123)" ]
  printf '%s\n' "$output" | grep -q '^OK process A_MT4 pid=123$'
}

@test "DR-AA-3c: MT4 running with /config: (ignored by MT4; the old start or an old Z: path) is NG without showing it" {
  local a
  aa_enable
  aa_make_ini
  for a in '/config:C:\atst\startup_a_mt4.ini' '/config:Z:\home\u\.atst\startup_a_mt4.ini'; do
    aa_proc 'C:\Program Files\A_MT4\terminal.exe' "$a"
    doctor_run
    [ "$status" -eq 1 ]
    [ "$(ini_line)" = "NG auto_attach A_MT4 running with /config:, which MT4 ignores (pid=123)" ]
    printf '%s\n' "$output" | grep -qxF '  auto_attach A_MT4: mtctl.sh stop and start pass C:\atst\startup_a_mt4.ini'
    [[ $output != *Z:* ]]
  done
  # another bare ini is not ours
  aa_proc 'C:\Program Files\A_MT4\terminal.exe' 'C:\atst\startup_a_mt4x.ini'
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(ini_line)" = "NG auto_attach A_MT4 running without the ini argument (pid=123)" ]
}

@test "DR-AA-3d: MT5 needs /config:C:\\atst\\...; the bare path or another /config: is NG" {
  local hash5=B1B2C3D4E5F60718293A4B5C6D7E8F90
  atst_test_make_mt B_MT5 MT5 "$hash5"
  atst_test_set_targets B_MT5
  aa_enable
  mkdir -p "$WINEPREFIX/drive_c/atst" && chmod 700 "$WINEPREFIX/drive_c/atst"
  atst_test_source_common
  atst_startup_ini_content MT5 EURUSD M5 > "$WINEPREFIX/drive_c/atst/startup_b_mt5.ini"
  chmod 600 "$WINEPREFIX/drive_c/atst/startup_b_mt5.ini"
  rm -rf "${ATST_PROC_ROOT:?}/123"
  atst_test_make_proc 125 - "$(printf 'HOME=%s\nWINEPREFIX=%s' "$HOME" "$WINEPREFIX")" \
    'C:\Program Files\B_MT5\terminal.exe' '/config:C:\atst\startup_b_mt5.ini'
  doctor_run
  [ "$(ini_line)" = "OK auto_attach B_MT5 ini ok, /config: passed (pid=125)" ]
  rm -rf "${ATST_PROC_ROOT:?}/125"
  atst_test_make_proc 125 - "$(printf 'HOME=%s\nWINEPREFIX=%s' "$HOME" "$WINEPREFIX")" \
    'C:\Program Files\B_MT5\terminal.exe' 'C:\atst\startup_b_mt5.ini'
  doctor_run
  [ "$(ini_line)" = "NG auto_attach B_MT5 running without /config: (pid=125)" ]
  printf '%s\n' "$output" | grep -qxF '  auto_attach B_MT5: mtctl.sh stop and start pass /config:C:\atst\startup_b_mt5.ini'
  rm -rf "${ATST_PROC_ROOT:?}/125"
  atst_test_make_proc 125 - "$(printf 'HOME=%s\nWINEPREFIX=%s' "$HOME" "$WINEPREFIX")" \
    'C:\Program Files\B_MT5\terminal.exe' '/config:Z:\home\u\.atst\startup_b_mt5.ini'
  doctor_run
  [ "$(ini_line)" = "NG auto_attach B_MT5 running with another /config: (pid=125)" ]
  [[ $output != *Z:* ]]
}

@test "DR-AA-4a: enabled, ini ok, a running MT4 without the ini argument is NG" {
  aa_enable
  aa_make_ini
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(ini_line)" = "NG auto_attach A_MT4 running without the ini argument (pid=123)" ]
}

@test "DR-AA-4b: an ini of mode 644 is NG and doctor does not chmod it" {
  aa_enable
  aa_make_ini
  chmod 644 "$WINEPREFIX/drive_c/atst/startup_a_mt4.ini"
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(ini_line)" = "NG auto_attach A_MT4 mode 644 (must be 600): $WINEPREFIX/drive_c/atst/startup_a_mt4.ini" ]
  [ "$(stat -c %a "$WINEPREFIX/drive_c/atst/startup_a_mt4.ini")" = 644 ]
}

@test "DR-AA-4c: an ini that differs from the config (period H1) is NG" {
  aa_enable EURUSD H1
  aa_make_ini
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(ini_line)" = "NG auto_attach A_MT4 content differs from the config: $WINEPREFIX/drive_c/atst/startup_a_mt4.ini" ]
}

@test "DR-AA-4d: a wrong symbol or period is NG without showing the value" {
  aa_enable 'EURUSD;Login=1' M5
  aa_make_ini
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(ini_line)" = "NG auto_attach A_MT4 ATST_AUTO_ATTACH_SYMBOL is empty or invalid" ]
  [[ $output != *Login* ]]
  aa_enable EURUSD M2
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(ini_line)" = "NG auto_attach A_MT4 ATST_AUTO_ATTACH_PERIOD is empty or invalid" ]
  [[ $(ini_line) != *M2* ]]
}

@test "DR-AA-4e: ini ok and MetaTrader stopped is OK not running" {
  aa_enable
  aa_make_ini
  rm -rf "${ATST_PROC_ROOT:?}/123"
  doctor_run
  [ "$(ini_line)" = "OK auto_attach A_MT4 ini ok, not running" ]
}

@test "DR-AA-4f: drive_c/atst of mode 755 is NG" {
  aa_enable
  aa_make_ini
  chmod 755 "$WINEPREFIX/drive_c/atst"
  aa_proc 'C:\Program Files\A_MT4\terminal.exe' 'C:\atst\startup_a_mt4.ini'
  doctor_run
  [ "$status" -eq 1 ]
  [ "$(ini_line)" = "NG auto_attach A_MT4 dir mode 755 (must be 700): $WINEPREFIX/drive_c/atst" ]
}

@test "DR-AA-5: auto_attach OK with csv NG adds a note" {
  aa_enable
  aa_make_ini
  aa_proc 'C:\Program Files\A_MT4\terminal.exe' 'C:\atst\startup_a_mt4.ini'
  : > "$(doctor_data_dir)/MQL4/Files/terminal_monitoring.csv"
  doctor_make_csv 400
  doctor_run
  [ "$(ini_line)" = "OK auto_attach A_MT4 ini ok, ini argument passed (pid=123)" ]
  printf '%s\n' "$output" | grep -q '^NG csv A_MT4 '
  [ "$(printf '%s\n' "$output" | grep -cxF '  auto_attach A_MT4: the ini is passed but no fresh CSV; the StartUp may not work (see ~/.atst/wine_a_mt4.log)')" -eq 1 ]
}

# doctor_make_csv14 <secs_ago>: one 14-field line (the monitoring EA of #158) in the data folder.
doctor_make_csv14() {
  local src dst

  doctor_in_sandbox || return 1
  atst_test_make_monitoring_csv A_MT4 "$1" 150.000 10 0.01 12 '' '1,1,1,1,0,0.00' || return 1
  src="$WINEPREFIX/drive_c/Program Files/A_MT4/MQL4/Files/terminal_monitoring.csv"
  dst="$(doctor_data_dir)/MQL4/Files/terminal_monitoring.csv"
  cat "$src" >> "$dst" && rm -f "$src"
}

@test "DR-COLS-1: an 8-field CSV shows cols 8 and one note about the old EA; still OK (#158)" {
  doctor_run
  [ "$status" -eq 0 ]
  [ -n "$(printf '%s\n' "$output" | grep -E '^OK csv A_MT4 last update [0-9]+s ago cols 8$')" ]
  [ "$(printf '%s\n' "$output" | grep -c '^  the monitoring EA is old (8 fields): check_trade_ready\.sh does not work until the EA is updated (setup_monitoring_ea\.sh) and attached again$')" -eq 1 ]
  [[ "${lines[${#lines[@]}-1]}" == *" ng=0 "* ]]
}

@test "DR-COLS-2: a 14-field CSV shows cols 14 and no note (#158)" {
  rm -f "$(doctor_data_dir)/MQL4/Files/terminal_monitoring.csv"
  doctor_make_csv14 10
  doctor_run
  [ "$status" -eq 0 ]
  [ -n "$(printf '%s\n' "$output" | grep -E '^OK csv A_MT4 last update [0-9]+s ago cols 14$')" ]
  [ "$(printf '%s\n' "$output" | grep -c 'monitoring EA is old')" -eq 0 ]
}

@test "DR-COLS-3: an old 8-field CSV is NG with cols 8 and the note (#158)" {
  rm -f "$(doctor_data_dir)/MQL4/Files/terminal_monitoring.csv"
  doctor_make_csv 400
  doctor_run
  [ "$status" -eq 1 ]
  [ -n "$(printf '%s\n' "$output" | grep -E '^NG csv A_MT4 last update [0-9]+s ago \(threshold 180s\) cols 8$')" ]
  [ "$(printf '%s\n' "$output" | grep -c 'monitoring EA is old (8 fields)')" -eq 1 ]
}

@test "DR-COLS-4: the number of fields is that of the last data line (14 then 8 gives cols 8) (#158)" {
  rm -f "$(doctor_data_dir)/MQL4/Files/terminal_monitoring.csv"
  doctor_make_csv14 20
  doctor_make_csv 10
  doctor_run
  [ "$status" -eq 0 ]
  [ -n "$(printf '%s\n' "$output" | grep -E '^OK csv A_MT4 last update [0-9]+s ago cols 8$')" ]
}
