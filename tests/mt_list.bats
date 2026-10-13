#!/usr/bin/env bats
# atst_load_mt_list (common.sh): which MetaTrader installs land in mt_term / mt_home / mt_data /
# mt_name / mt_type, for folder names with characters a shell would treat specially (#93).
# common.sh is read without "run" so that the arrays stay in the test shell.

load test_helper

setup() {
  atst_test_setup_sandbox
  T="$WINEPREFIX/drive_c/users/tester/AppData/Roaming/MetaQuotes/Terminal"
  P="$WINEPREFIX/drive_c/Program Files"
}

teardown() {
  atst_test_teardown_sandbox
}

# Reads common.sh with its stderr in $ATST_TEST_SANDBOX/stderr.
source_common_to_stderr_file() {
  atst_test_source_common 2> "$ATST_TEST_SANDBOX/stderr"
}

# assert_single_mt <folder name> <expected mt_name> <expected mt_data>
# Checks that exactly one MT4 was loaded from "Program Files/<folder name>" and nothing went to stderr.
assert_single_mt() {
  local folder="$1" name="$2" data="$3"

  [ "${#mt_home[@]}" -eq 1 ]
  [ "${#mt_term[@]}" -eq 1 ]
  [ "${#mt_data[@]}" -eq 1 ]
  [ "${#mt_name[@]}" -eq 1 ]
  [ "${#mt_type[@]}" -eq 1 ]
  [ "${mt_home[0]}" = "$P/$folder" ]
  [ "${mt_term[0]}" = "$P/$folder/terminal.exe" ]
  [ "${mt_name[0]}" = "$name" ]
  [ "${mt_data[0]}" = "$data" ]
  [ "${mt_type[0]}" = MT4 ]
  [ ! -s "$ATST_TEST_SANDBOX/stderr" ]
}

@test "N1: a folder name with a single quote is loaded as it is" {
  atst_test_make_mt "It's MT4" MT4 H1
  source_common_to_stderr_file
  assert_single_mt "It's MT4" "IT'S MT4" "$T/H1"
}

@test "N2: a folder name with consecutive spaces keeps them" {
  atst_test_make_mt "A  B MT4" MT4 H1
  source_common_to_stderr_file
  assert_single_mt "A  B MT4" "A  B MT4" "$T/H1"
}

@test "N3: a folder name with glob characters is not expanded" {
  atst_test_make_mt "A[1]*MT4" MT4 H1
  source_common_to_stderr_file
  assert_single_mt "A[1]*MT4" "A[1]*MT4" "$T/H1"
}

@test "N4: a Japanese folder name is loaded and only its ASCII letters are upper-cased" {
  atst_test_make_mt "テスト_MT4" MT4 H1
  source_common_to_stderr_file
  assert_single_mt "テスト_MT4" "テスト_MT4" "$T/H1"
}

@test "N5: a folder name with a backslash keeps it, and mt_data is the install folder" {
  atst_test_make_mt 'A\B MT4' MT4
  source_common_to_stderr_file
  assert_single_mt 'A\B MT4' 'A\B MT4' "$P/A\\B MT4"
}

@test "N6: a single quote in one name does not shift the indexes of the others" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt "It's MT4" MT4 H1
  atst_test_make_mt Z_MT5 MT5
  source_common_to_stderr_file
  [ "${#mt_home[@]}" -eq 3 ]
  [ "${#mt_name[@]}" -eq 3 ]
  [ "${#mt_data[@]}" -eq 3 ]
  [ "${mt_name[0]}" = A_MT4 ]
  [ "${mt_name[1]}" = "IT'S MT4" ]
  [ "${mt_name[2]}" = Z_MT5 ]
  [ "${mt_home[1]}" = "$P/It's MT4" ]
  [ "${mt_data[1]}" = "$T/H1" ]
  [ "${mt_type[0]}" = MT4 ]
  [ "${mt_type[2]}" = MT5 ]
  [ ! -s "$ATST_TEST_SANDBOX/stderr" ]
}

@test "N7: without the Wine prefix, common.sh is read successfully and every array is empty" {
  [ ! -d "$WINEPREFIX" ]
  atst_test_source_common
  [ "${#mt_term[@]}" -eq 0 ]
  [ "${#mt_home[@]}" -eq 0 ]
  [ "${#mt_data[@]}" -eq 0 ]
  [ "${#mt_name[@]}" -eq 0 ]
  [ "${#mt_type[@]}" -eq 0 ]
}

@test "N8: a folder without MQL4/MQL5 is skipped with a message on stderr" {
  atst_test_make_mt A_MT4 MT4
  mkdir -p "$P/NOMQL"
  : > "$P/NOMQL/terminal.exe"
  source_common_to_stderr_file
  [ "${#mt_home[@]}" -eq 1 ]
  [ "${mt_name[0]}" = A_MT4 ]
  grep -q 'cannot determine MT4/MT5' "$ATST_TEST_SANDBOX/stderr"
}

@test "N9: reloading drops removed installs, returns 0 and does not set i" {
  atst_test_make_mt A_MT4 MT4
  atst_test_make_mt B_MT4 MT4
  unset i
  atst_test_source_common
  [ "${#mt_home[@]}" -eq 2 ]
  [ -z "${i+x}" ]
  mv "$P/B_MT4" "$ATST_TEST_SANDBOX/B_MT4.moved"
  atst_load_mt_list
  [ "${#mt_term[@]}" -eq 1 ]
  [ "${#mt_home[@]}" -eq 1 ]
  [ "${#mt_data[@]}" -eq 1 ]
  [ "${#mt_name[@]}" -eq 1 ]
  [ "${#mt_type[@]}" -eq 1 ]
  [ "${mt_name[0]}" = A_MT4 ]
  [ -z "${i+x}" ]
}

@test "N10: installs on other drives and Program Files (x86) are found, in path order" {
  local d="$WINEPREFIX/drive_d/Program Files (x86)/D_MT4"
  atst_test_make_mt A_MT4 MT4
  mkdir -p "$d/MQL4"
  : > "$d/terminal.exe"
  atst_test_source_common
  [ "${#mt_home[@]}" -eq 2 ]
  [ "${mt_name[0]}" = A_MT4 ]
  [ "${mt_name[1]}" = D_MT4 ]
  [ "${mt_home[1]}" = "$d" ]
  [ "${mt_type[1]}" = MT4 ]
}
