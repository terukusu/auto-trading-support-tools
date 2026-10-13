#!/usr/bin/env bats
# atst_gen_mt_list (common.sh): which data folder mt_data[] points to, from origin.txt and the
# mtime of logs/ (PR #75, #76).

load test_helper

setup() {
  atst_test_setup_sandbox
  T="$WINEPREFIX/drive_c/users/tester/AppData/Roaming/MetaQuotes/Terminal"
}

teardown() {
  atst_test_teardown_sandbox
}

@test "D1: origin.txt without BOM, in lower case and with a trailing backslash still maps to the AppData folder" {
  atst_test_make_mt A_MT4 MT4 H1
  printf '%s' 'c:\program files\a_mt4\' | iconv -f UTF-8 -t UTF-16LE > "$T/H1/origin.txt"
  atst_test_source_common
  [ "${mt_data[0]}" = "$T/H1" ]
}

@test "D2: two data folders for one install resolve to the one with the newer logs, not by name" {
  local other="$WINEPREFIX/drive_c/users/aaa/AppData/Roaming/MetaQuotes/Terminal/AAA"
  atst_test_make_mt A_MT4 MT4 ZZZ
  mkdir -p "$other/MQL4/Files" "$other/logs"
  cp "$T/ZZZ/origin.txt" "$other/origin.txt"
  touch -d '2 days ago' "$T/ZZZ/logs"
  touch -d '1 day ago' "$other/logs"
  atst_test_source_common
  [ "${mt_data[0]}" = "$other" ]
  touch -d '1 hour ago' "$T/ZZZ/logs"
  eval "$(atst_gen_mt_list)"
  [ "${mt_data[0]}" = "$T/ZZZ" ]
}

@test "D3: the install folder wins when its logs are newer than the AppData logs" {
  local home="$WINEPREFIX/drive_c/Program Files/A_MT4"
  atst_test_make_mt A_MT4 MT4 H1
  mkdir -p "$home/logs"
  touch -d '1 hour ago' "$home/logs"
  touch -d '1 day ago' "$T/H1/logs"
  atst_test_source_common
  [ "${mt_data[0]}" = "$home" ]
}

@test "D4: a Japanese folder name maps to the AppData folder" {
  atst_test_make_mt テスト_MT4 MT4 H1
  atst_test_source_common
  [ "${mt_data[0]}" = "$T/H1" ]
}
