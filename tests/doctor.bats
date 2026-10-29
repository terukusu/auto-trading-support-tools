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
  [ -n "$(printf '%s\n' "$output" | grep '^-- heartbeat ATST_HEARTBEAT_URL not set$')" ]
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
