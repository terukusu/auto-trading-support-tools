#!/usr/bin/env bats
# Fixture check: common.sh can be read inside the sandbox (not a regression test).

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

# Prints the index of the MT named $1 (mt_name is upper case).
mt_index_of() {
  local i
  for i in "${!mt_name[@]}"; do
    if [ "${mt_name[$i]}" = "$1" ]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

@test "common.sh creates config under the sandbox HOME" {
  atst_test_source_common || return 1
  [ "$HOME" = "$ATST_TEST_SANDBOX/home" ]
  [ -f "$HOME/.atst/config" ]
}

@test "mt_home has as many entries as the MTs made" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt B_MT5 MT5 0123456789ABCDEF0123456789ABCDEF
  atst_test_source_common || return 1
  [ "${#mt_home[@]}" -eq 2 ]
}

@test "mt_data points to AppData when origin.txt exists" {
  local hash=0123456789ABCDEF0123456789ABCDEF idx
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt B_MT5 MT5 "$hash"
  atst_test_source_common || return 1
  idx=$(mt_index_of B_MT5)
  [ -n "$idx" ]
  [ "${mt_type[$idx]}" = MT5 ]
  [ "${mt_data[$idx]}" = "$WINEPREFIX/drive_c/users/tester/AppData/Roaming/MetaQuotes/Terminal/$hash" ]
}

@test "mt_data points to the install folder without origin.txt" {
  local idx
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt B_MT5 MT5 0123456789ABCDEF0123456789ABCDEF
  atst_test_source_common || return 1
  idx=$(mt_index_of A_MT4)
  [ -n "$idx" ]
  [ "${mt_type[$idx]}" = MT4 ]
  [ "${mt_data[$idx]}" = "$WINEPREFIX/drive_c/Program Files/A_MT4" ]
}

@test "atst_log prints its arguments after the timestamp" {
  atst_test_source_common || return 1
  run atst_log "a b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"] a b" ]]
}
