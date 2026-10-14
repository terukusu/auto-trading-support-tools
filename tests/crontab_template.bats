#!/usr/bin/env bats
# templates/crontab.txt (#95): no crontab TARGET, one per-minute line, every job runs a script of the
# repository, and the jobs needing MetaTrader names get them from ATST_TARGETS through
# run_with_targets.sh, which runs nothing but its three scripts.

load test_helper

setup() {
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  T="$repo/templates/crontab.txt"
  CALLS="$ATST_TEST_SANDBOX/calls.log"
}

teardown() {
  atst_test_teardown_sandbox
}

# calls.log without the epoch column.
calls() {
  sed -E 's/ [0-9]+//' "$CALLS"
}

# The command part of each job line of the template (no comments, blank lines or VAR= lines).
job_commands() {
  grep -vE '^[[:space:]]*(#|$)' "$T" | grep -vE '^[A-Z_]+=' |
    sed -E 's/^(@reboot|[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+) +//'
}

@test "CT-01: no crontab TARGET and one per-minute line (AC2)" {
  [ "$(grep -c -e '^TARGET=' -e '\$TARGET' "$T")" -eq 0 ]
  [ "$(grep -c '^\*  *\* \* \* \*' "$T")" -eq 1 ]
}

@test "CT-02: every job runs a script of the repository (AC2)" {
  local cmd first second n=0
  while IFS= read -r cmd; do
    n=$(( n + 1 ))
    read -r first second _ <<< "$cmd"
    [ -x "$repo/$first" ] || { echo "missing: $first"; false; }
    if [ "$first" = run_with_targets.sh ]; then
      [ -x "$repo/$second" ] || { echo "missing: $second"; false; }
    fi
  done < <(job_commands)
  [ "$n" -eq 5 ]
}

@test "CT-03: the run_with_targets.sh jobs pass ATST_TARGETS element by element (AC2, AC3)" {
  local home cmd n=0 expected
  home=$(atst_test_make_runner_home)
  atst_test_stub_script "$home" mtctl.sh record
  atst_test_stub_script "$home" truncate_monitoring.sh record
  atst_test_stub_script "$home" report_image.sh record
  atst_test_set_targets "it's" 'a  b'
  while IFS= read -r cmd; do
    n=$(( n + 1 ))
    PATH="$home:$BATS_TEST_DIRNAME/stubs:/bin:/usr/bin:/usr/local/bin" sh -c "$cmd"
  done < <(job_commands | grep 'run_with_targets\.sh')
  [ "$n" -eq 3 ]
  expected="mtctl.sh [start] [it's] [a  b]
truncate_monitoring.sh [it's] [a  b]
report_image.sh [it's] [a  b]"
  [ "$(calls)" = "$expected" ]
}

@test "RWT-01: run_with_targets.sh runs nothing for a script outside its list" {
  local home a
  home=$(atst_test_make_runner_home)
  atst_test_stub_script "$home" mtctl.sh record
  # Would be recorded if ../x.sh got through.
  atst_test_stub_script "$ATST_TEST_SANDBOX" x.sh record
  atst_test_set_targets A
  run bash "$home/run_with_targets.sh"
  [ "$status" -eq 1 ]
  for a in rm ../x.sh ./mtctl.sh check_all.sh; do
    run bash "$home/run_with_targets.sh" "$a"
    [ "$status" -eq 1 ] || { echo "arg=$a"; false; }
  done
  [ ! -e "$CALLS" ]
  [ ! -e "$HOME/.atst/check_all.started" ]
}

@test "RWT-02: run_with_targets.sh with ATST_TARGETS unset exits 1 without running or notifying" {
  local home
  home=$(atst_test_make_runner_home)
  atst_test_stub_script "$home" mtctl.sh record
  atst_test_set_targets A
  sed -i '/^ATST_TARGETS=/d' "$HOME/.atst/config"
  run bash "$home/run_with_targets.sh" mtctl.sh start
  [ "$status" -eq 1 ]
  [ ! -e "$CALLS" ]
  [ "$(atst_test_push_count)" -eq 0 ]
  [[ "$output" == *ATST_TARGETS* ]]
}

@test "RWT-03: run_with_targets.sh exits with the script's exit code" {
  local home
  home=$(atst_test_make_runner_home)
  atst_test_stub_script "$home" mtctl.sh fail
  atst_test_set_targets A
  run bash "$home/run_with_targets.sh" mtctl.sh start
  [ "$status" -eq 3 ]
}
