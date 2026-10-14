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

@test "HT-01: atst_has_targets is true only for at least one element and no empty one (#95)" {
  local i expected=(1 1 1 1 0 0 0)
  atst_test_source_common || return 1
  for i in 0 1 2 3 4 5 6; do
    unset ATST_TARGETS
    case "$i" in
      0) ;;
      1) ATST_TARGETS=() ;;
      2) ATST_TARGETS=('') ;;
      3) ATST_TARGETS=('a' '') ;;
      4) ATST_TARGETS=('a') ;;
      5) ATST_TARGETS='Land Prime' ;;
      6) ATST_TARGETS=([1]=a) ;;
    esac
    run atst_has_targets
    [ "$status" -eq "${expected[$i]}" ] || { echo "case $i: status=$status"; false; }
    [ -z "$output" ]
  done
}

@test "D6-01: ATST_TARGETS, ATST_CHECK_TIMEOUT and ATST_ORDER_CHECK_INTERVAL come from the config only" {
  mkdir -p "$HOME/.atst"
  cp "$BATS_TEST_DIRNAME/../templates/config" "$HOME/.atst/config"
  sed -i -e '/^ATST_TARGETS=/d' -e '/^ATST_CHECK_TIMEOUT=/d' -e '/^ATST_ORDER_CHECK_INTERVAL=/d' "$HOME/.atst/config"
  export ATST_TARGETS=X ATST_CHECK_TIMEOUT=7 ATST_ORDER_CHECK_INTERVAL=7
  atst_test_source_common || return 1
  [ -z "${ATST_TARGETS+x}" ]
  [ -z "${ATST_CHECK_TIMEOUT+x}" ]
  [ -z "${ATST_ORDER_CHECK_INTERVAL+x}" ]
  run atst_has_targets
  [ "$status" -eq 1 ]
}
