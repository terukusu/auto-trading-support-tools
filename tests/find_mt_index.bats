#!/usr/bin/env bats
# atst_find_mt_index (common.sh): the TARGET name is a literal, case-insensitive prefix of the
# folder name (#107). common.sh is read without "run" so that mt_name / mt_term stay in the
# test shell; the lookups themselves run with "run" or with their output in files.

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

# index_of <upper-cased folder name>
# Prints the index k with mt_name[k] equal to the argument (the order of mt_name follows sort,
# so tests look the index up instead of assuming it). Fails when there is none.
index_of() {
  local k
  for k in "${!mt_name[@]}"; do
    if [ "${mt_name[k]}" = "$1" ]; then
      echo "$k"
      return 0
    fi
  done
  return 1
}

# assert_no_match <target>
# Checks that atst_find_mt_index prints nothing to stdout or stderr and returns 0.
assert_no_match() {
  local rc=0
  atst_find_mt_index "$1" > "$ATST_TEST_SANDBOX/out" 2> "$ATST_TEST_SANDBOX/err" || rc=$?
  [ "$rc" -eq 0 ]
  [ ! -s "$ATST_TEST_SANDBOX/out" ]
  [ ! -s "$ATST_TEST_SANDBOX/err" ]
}

# assert_match <target> <expected index>
# Checks that atst_find_mt_index prints only the index, nothing to stderr, and returns 0.
assert_match() {
  local rc=0
  atst_find_mt_index "$1" > "$ATST_TEST_SANDBOX/out" 2> "$ATST_TEST_SANDBOX/err" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(cat "$ATST_TEST_SANDBOX/out")" = "$2" ]
  [ ! -s "$ATST_TEST_SANDBOX/err" ]
}

@test "consecutive spaces in the folder name and the target match" {
  atst_test_make_mt "A  B MT4" MT4
  atst_test_source_common
  [ "${#mt_name[@]}" -eq 1 ]
  [ "${mt_name[0]}" = "A  B MT4" ]

  run atst_find_mt_index "A  B"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]

  run atst_find_mt_index "a  b mt4"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]

  # One space is not the same name as two spaces.
  run atst_find_mt_index "A B"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a single quote with consecutive spaces matches" {
  atst_test_make_mt "It's  MT4" MT4
  atst_test_source_common
  [ "${mt_name[0]}" = "IT'S  MT4" ]

  run atst_find_mt_index "it's  MT4"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]

  run atst_find_mt_index "It's MT4"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "glob characters are literal and are not expanded against files in the current directory" {
  local plain bracket star

  atst_test_make_mt "A1 MT4" MT4
  atst_test_make_mt "A[1]*MT4" MT4
  atst_test_make_mt "Z*" MT4
  atst_test_source_common
  [ "${#mt_name[@]}" -eq 3 ]
  plain=$(index_of "A1 MT4")
  bracket=$(index_of "A[1]*MT4")
  star=$(index_of "Z*")

  # Files a glob such as Z* would expand to.
  mkdir -p "$ATST_TEST_SANDBOX/cwd"
  : > "$ATST_TEST_SANDBOX/cwd/ZZ1"
  : > "$ATST_TEST_SANDBOX/cwd/ZZ2"
  cd "$ATST_TEST_SANDBOX/cwd"

  assert_match "A[1]" "$bracket"
  assert_match "a[1]*" "$bracket"
  assert_match "A[1]*MT4" "$bracket"
  assert_match "A1" "$plain"
  assert_match "Z*" "$star"
  assert_no_match "A?"
  assert_no_match "ZZ1"
  assert_no_match "*"
  assert_no_match "[A]"
}

@test "parentheses, a backslash and other regular expression characters are literal, without stderr" {
  local land paren

  atst_test_make_mt "Land Prime MT4" MT4
  atst_test_make_mt 'MT4 (1) a\b|c' MT4
  atst_test_source_common
  [ "${#mt_name[@]}" -eq 2 ]
  land=$(index_of "LAND PRIME MT4")
  paren=$(index_of 'MT4 (1) A\B|C')

  assert_match "MT4 (1)" "$paren"
  assert_match 'MT4 (1) a\b|c' "$paren"
  assert_match "Land Prime" "$land"

  # Regular expressions are no longer read as such (and an invalid one prints no grep error).
  assert_no_match "("
  assert_no_match "["
  assert_no_match 'a\'
  assert_no_match "Land.Prime"
  assert_no_match ".*"
  assert_no_match ".+"
  assert_no_match "Land|Xyz"
  assert_no_match 'MT4 \(1\)'
}

@test "a folder name starting with -e is not read as an echo option" {
  atst_test_make_mt "-e FOO" MT4
  atst_test_source_common
  [ "${#mt_name[@]}" -eq 1 ]
  [ "${mt_name[0]}" = "-E FOO" ]

  assert_no_match "FOO"
  assert_match "-e" 0
  assert_match "-E FOO" 0
}

@test "unchanged: case-insensitive prefix match only, the first index, and nothing for an empty or unknown name" {
  local land mt5a mt5b

  atst_test_make_mt "Land Prime MetaTrader 4 Terminal" MT4
  atst_test_make_mt "MetaTrader 5 A" MT5
  atst_test_make_mt "MetaTrader 5 B" MT5
  atst_test_source_common
  [ "${#mt_name[@]}" -eq 3 ]
  land=$(index_of "LAND PRIME METATRADER 4 TERMINAL")
  mt5a=$(index_of "METATRADER 5 A")
  mt5b=$(index_of "METATRADER 5 B")
  [ "$land" -eq 0 ]
  [ "$mt5a" -eq 1 ]
  [ "$mt5b" -eq 2 ]

  run atst_find_mt_index "land prime"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]

  run atst_find_mt_index "Land Prime MetaTrader 4 Terminal"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]

  # Prefix only: a name in the middle does not match.
  run atst_find_mt_index "Prime"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Several matches: the first index.
  run atst_find_mt_index "metatrader 5"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]

  run atst_find_mt_index "MetaTrader 5 b"
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]

  # Longer than the folder name.
  run atst_find_mt_index "Land Prime MetaTrader 4 Terminal X"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run atst_find_mt_index ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run atst_find_mt_index "No Such MT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the caller's i and match are left as they were" {
  atst_test_make_mt "A_MT4" MT4
  atst_test_make_mt "B_MT4" MT4
  atst_test_source_common
  [ "$(index_of "B_MT4")" -eq 1 ]

  i=99
  match=keep
  [ "$(atst_find_mt_index B)" = 1 ]
  atst_find_mt_index B > /dev/null
  [ "$i" -eq 99 ]
  [ "$match" = keep ]
  atst_find_mt_index "No Such MT" > /dev/null
  [ "$i" -eq 99 ]
  [ "$match" = keep ]
}

@test "atst_find_terminal finds each install by its own upper-cased name (mtctl.sh status)" {
  local k

  atst_test_make_mt "A  B MT4" MT4
  atst_test_make_mt "MT4 (1)" MT4
  atst_test_make_mt "X[1]*MT4" MT4
  atst_test_source_common
  [ "${#mt_name[@]}" -eq 3 ]

  for k in 0 1 2; do
    [ "$(atst_find_terminal "${mt_name[k]}")" = "${mt_term[k]}" ]
  done
}
