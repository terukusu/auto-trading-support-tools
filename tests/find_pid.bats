#!/usr/bin/env bats
# common.sh atst_find_pid: finds the MetaTrader process by reading a fake /proc tree
# (ATST_PROC_ROOT, made by atst_test_make_proc) without winepath or ps.

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

# environ of a process started by us in the sandbox prefix
own_env() {
  printf 'HOME=%s\nWINEPREFIX=%s' "$HOME" "$WINEPREFIX"
}

# Windows form of the terminal.exe of the MT made by atst_test_make_mt <name>
win_term() {
  printf 'C:\\Program Files\\%s\\terminal.exe' "$1"
}

@test "F1: a Windows argv[0] with WINEPREFIX in environ prints its pid" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "F2: a unix argv[0] (mt_term itself) matches without any prefix in environ" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "" "$WINEPREFIX/drive_c/Program Files/A_MT4/terminal.exe"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "F3: a folder name with ', blanks, [ and * matches its exact argv[0]" {
  atst_test_make_mt "It's  A[1]* MT4" MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" "$(win_term "It's  A[1]* MT4")"
  run atst_find_pid It
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "F4: a longer folder name or a suffixed exe does not match" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt A_MT4X MT4
  atst_test_source_common
  # A_MT4 itself is the target (the prefix match of the name is #107, not this test)
  [ "$(atst_find_terminal A_MT4)" = "$WINEPREFIX/drive_c/Program Files/A_MT4/terminal.exe" ]
  atst_test_make_proc 123 - "$(own_env)" "$(win_term A_MT4X)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  rm -rf "${ATST_PROC_ROOT:?}/123"
  atst_test_make_proc 124 - "$(own_env)" "$(win_term A_MT4).bak"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "F5: a Windows argv[0] from another prefix does not match" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  mkdir -p "$ATST_TEST_SANDBOX/other"
  atst_test_make_proc 123 - "HOME=$HOME"$'\n'"WINEPREFIX=$ATST_TEST_SANDBOX/other" "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "F6: without WINEPREFIX in environ, HOME/.wine is the prefix" {
  WINEPREFIX="$HOME/.wine"
  export WINEPREFIX
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "HOME=$HOME" "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "F7: a process of another user does not match" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 "$((EUID + 1))" "$(own_env)" "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "F8: several matches print the numerically smallest pid only" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 100 - "$(own_env)" "$(win_term A_MT4)"
  atst_test_make_proc 99 - "$(own_env)" "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "99" ]
}

@test "F9: non-numeric entries, empty cmdline and missing environ are skipped" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc self - "$(own_env)" "$(win_term A_MT4)"
  atst_test_make_proc 50 - "$(own_env)"
  atst_test_make_proc 60 - - "$(win_term A_MT4)"
  atst_test_make_proc 70 - "$(own_env)" "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "70" ]
}

@test "F10: no matching process or no matching MT name prints nothing" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" /bin/sleep 30
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  atst_test_make_proc 124 - "$(own_env)" "$(win_term A_MT4)"
  run atst_find_pid NOSUCH
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "F11: argv[1] is used after wine-preloader, but not a path among later arguments" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" /usr/lib/wine/wine64-preloader "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
  rm -rf "${ATST_PROC_ROOT:?}/123"
  atst_test_make_proc 124 - "$(own_env)" wine start /b /d "$WINEPREFIX/drive_c/Program Files/A_MT4" \
    /unix "$WINEPREFIX/drive_c/Program Files/A_MT4/terminal.exe"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "F12: WINEPREFIX with a trailing / or through a symlink matches (physical path)" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "HOME=$HOME"$'\n'"WINEPREFIX=$WINEPREFIX/" "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
  rm -rf "${ATST_PROC_ROOT:?}/123"
  ln -s "$WINEPREFIX" "$ATST_TEST_SANDBOX/link"
  atst_test_make_proc 124 - "HOME=$HOME"$'\n'"WINEPREFIX=$ATST_TEST_SANDBOX/link" "$(win_term A_MT4)"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "124" ]
}

@test "F13: an argv[0] quoted with \" matches" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" "\"$(win_term A_MT4)\""
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "F14: a missing ATST_PROC_ROOT prints nothing and returns 0" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  ATST_PROC_ROOT="$ATST_TEST_SANDBOX/no-such-proc"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# #133: mtctl.sh start may pass /config:<ini> after terminal.exe. Wine may show it as a separate argv
# element or joined to argv[0] with a blank; both must match, nothing else may start to match.

@test "F15: a Windows argv[0] followed by a separate /config: element matches" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" "$(win_term A_MT4)" '/config:C:\atst\startup_a_mt4.ini'
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "F16: /config: joined to the Windows argv[0] with a blank or a tab matches" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" "$(win_term A_MT4) /config:C:\\atst\\startup_a_mt4.ini"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
  rm -rf "${ATST_PROC_ROOT:?}/123"
  atst_test_make_proc 124 - "$(own_env)" "$(win_term A_MT4)"$'\t''/config:x'
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "124" ]
}

@test "F17: a quoted Windows argv[0] joined to /config: matches" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" "\"$(win_term A_MT4)\" /config:x"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "F18a: a suffixed exe or a longer folder name joined to /config: does not match" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt A_MT4X MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" "$(win_term A_MT4).bak /config:x"
  atst_test_make_proc 124 - "$(own_env)" "$(win_term A_MT4X) /config:x"
  atst_test_make_proc 125 - "$(own_env)" "$(win_term A_MT4)x /config:x"
  atst_test_make_proc 126 - "$(own_env)" "$(win_term A_MT4)/config:x"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "F18b: the joined form of another user or another prefix does not match" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 "$((EUID + 1))" "$(own_env)" "$(win_term A_MT4) /config:x"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  rm -rf "${ATST_PROC_ROOT:?}/123"
  mkdir -p "$ATST_TEST_SANDBOX/other"
  atst_test_make_proc 124 - "HOME=$HOME"$'\n'"WINEPREFIX=$ATST_TEST_SANDBOX/other" "$(win_term A_MT4) /config:x"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "F18c: a wine start line with /config: and a shell holding the joined form do not match" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" /usr/bin/wine start /b /d 'C:\Program Files\A_MT4' \
    /unix "$WINEPREFIX/drive_c/Program Files/A_MT4/terminal.exe" '/config:C:\atst\startup_a_mt4.ini'
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  rm -rf "${ATST_PROC_ROOT:?}/123"
  atst_test_make_proc 124 - "$(own_env)" bash "$(win_term A_MT4) /config:x"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "F19: a unix argv[0] and argv[1] after wine64-preloader joined to /config: match" {
  atst_test_make_mt A_MT4 MT4
  atst_test_source_common
  atst_test_make_proc 123 - "" "$WINEPREFIX/drive_c/Program Files/A_MT4/terminal.exe /config:x"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
  rm -rf "${ATST_PROC_ROOT:?}/123"
  atst_test_make_proc 124 - "$(own_env)" /usr/lib/wine/wine64-preloader "$(win_term A_MT4) /config:x"
  run atst_find_pid A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "124" ]
}

@test "F3g: a folder name with ', blanks, [ and * matches joined to /config: and is not a pattern" {
  atst_test_make_mt "It's  A[1]* MT4" MT4
  atst_test_source_common
  atst_test_make_proc 123 - "$(own_env)" "$(win_term "It's  A[1]* MT4") /config:x"
  run atst_find_pid It
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
  rm -rf "${ATST_PROC_ROOT:?}/123"
  atst_test_make_proc 124 - "$(own_env)" "$(win_term "It's  A1X MT4") /config:x"
  run atst_find_pid It
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
