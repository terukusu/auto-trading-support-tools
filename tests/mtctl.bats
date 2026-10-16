#!/usr/bin/env bats
# mtctl.sh: exit status of list / status / stop on the sandbox (#101). start runs wine and is not tested here.

load test_helper

setup() {
  atst_test_setup_sandbox
  atst_test_make_mt A_MT4 MT4
}

teardown() {
  atst_test_teardown_sandbox
}

@test "MC-1: list with one MetaTrader exits 0" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1 MetaTrader found." ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[1]}" == *"name=A_MT4"* ]]
}

@test "MC-2: status of one stopped MetaTrader exits 0" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" status A_MT4
  [ "$status" -eq 0 ]
  [ "$output" = "status=stopped, pid= -, name=A_MT4" ]
}

@test "MC-3: status without a name prints usage and exits 1" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" status
  [ "$status" -eq 1 ]
}

@test "MC-4: stop of a MetaTrader that is not running exits 0" {
  run bash "$BATS_TEST_DIRNAME/../mtctl.sh" stop A_MT4
  [ "$status" -eq 0 ]
}
