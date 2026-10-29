#!/usr/bin/env bats
# truncate_monitoring.sh (#144): keeps the last 1 MB of ~/.atst/log/check_all.log once it passes 2 MB.
# The script runs as a subprocess from a copy in the sandbox with a name matching no MetaTrader (the
# trims run after the MT loop); curl is the stub in tests/stubs. The real ~/.atst is never touched.

load test_helper

setup() {
  atst_test_setup_sandbox
  home=$(atst_test_make_runner_home)
  D="$HOME/.atst/log"
  L="$D/check_all.log"
}

teardown() {
  # TRIM-06 takes permissions away; give them back so the sandbox can be removed.
  chmod -R u+rwX "$ATST_TEST_SANDBOX" 2>/dev/null
  atst_test_teardown_sandbox
}

# A 2.5 MB log of 80-column lines ending with LAST-LINE-9c1e (mode 600).
make_big_log() {
  mkdir -p "$D" || return 1
  chmod 700 "$D" || return 1
  yes "$(printf '%079d' 0)" | head -c 2621440 > "$L"
  echo LAST-LINE-9c1e >> "$L" || return 1
  chmod 600 "$L"
}

trim_run() {
  run bash "$home/truncate_monitoring.sh" NO_SUCH_MT
}

@test "TRIM-01: a log over 2 MB keeps its last 1 MB in the same inode and mode, no temp file left (AC-9)" {
  local i0 s
  make_big_log
  i0=$(stat -c %i "$L")
  trim_run
  [ "$status" -eq 0 ]
  s=$(stat -c %s "$L")
  [ "$s" -ge 1 ]
  [ "$s" -le 1048576 ]
  [ "$(tail -n 1 "$L")" = LAST-LINE-9c1e ]
  [ "$(stat -c %i "$L")" = "$i0" ]
  [ "$(stat -c %a "$L")" = 600 ]
  [ "$(ls "$D" | grep -c '^check_all\.log\.')" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "TRIM-02: a 1 MB log is left as it is (AC-9)" {
  local i0
  mkdir -p "$D"
  head -c 1048576 /dev/zero | tr '\0' x > "$L"
  cp "$L" "$ATST_TEST_SANDBOX/l.orig"
  i0=$(stat -c %i "$L")
  trim_run
  [ "$status" -eq 0 ]
  cmp "$L" "$ATST_TEST_SANDBOX/l.orig"
  [ "$(stat -c %i "$L")" = "$i0" ]
}

@test "TRIM-03: without the log nothing is made and it exits 0 (AC-9)" {
  trim_run
  [ "$status" -eq 0 ]
  [ ! -e "$D" ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "TRIM-04: a log of exactly 2 MB is left as it is" {
  mkdir -p "$D"
  head -c 2097152 /dev/zero | tr '\0' x > "$L"
  cp "$L" "$ATST_TEST_SANDBOX/l.orig"
  trim_run
  [ "$status" -eq 0 ]
  cmp "$L" "$ATST_TEST_SANDBOX/l.orig"
  [ "$(stat -c %s "$L")" -eq 2097152 ]
}

@test "TRIM-05: check_all.log as a directory is left alone without a temp file" {
  mkdir -p "$L"
  trim_run
  [ "$status" -eq 0 ]
  [ -d "$L" ]
  [ "$(ls "$D" | grep -c '^check_all\.log\.')" -eq 0 ]
}

@test "TRIM-06: when no temp file can be made, the log is left as it is and it exits 0" {
  [ "$EUID" -ne 0 ] || skip "root ignores permissions"
  make_big_log
  cp "$L" "$ATST_TEST_SANDBOX/l.orig"
  chmod 500 "$D"
  trim_run
  [ "$status" -eq 0 ]
  cmp "$L" "$ATST_TEST_SANDBOX/l.orig"
}
