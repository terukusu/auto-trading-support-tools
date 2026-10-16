#!/usr/bin/env bats
# atst_set_alert_status / atst_get_alert_status (common.sh): whole-key match, one line per key and
# no lost or duplicated lines under parallel updates (PR #73).

load test_helper

setup() {
  atst_test_setup_sandbox
}

teardown() {
  atst_test_teardown_sandbox
}

@test "A1: atst_get_alert_status returns the set value and the default for a missing key" {
  atst_test_source_common
  atst_set_alert_status KEY_A 1
  [ "$(atst_get_alert_status KEY_A)" = "1" ]
  [ -f "$ATST_ALERT_STATUS_FILE" ]
  [ "$(atst_get_alert_status NOKEY 9)" = "9" ]
}

@test "A2: alert_status keys match the whole first field only" {
  atst_test_source_common
  atst_set_alert_status PROCESS_X 1
  atst_set_alert_status PROCESS_X_2 2
  atst_set_alert_status XPROCESS_X 3
  [ "$(atst_get_alert_status PROCESS_X)" = "1" ]
  [ "$(atst_get_alert_status PROCESS_X_2)" = "2" ]
  [ "$(atst_get_alert_status XPROCESS_X)" = "3" ]
  [ "$(wc -l < "$ATST_ALERT_STATUS_FILE")" -eq 3 ]
}

@test "A3: setting a key twice keeps one line with the last value and an epoch time" {
  atst_test_source_common
  atst_set_alert_status KEY_A 1
  atst_set_alert_status KEY_A 0
  [ "$(grep -c '^KEY_A,' "$ATST_ALERT_STATUS_FILE")" -eq 1 ]
  [ "$(atst_get_alert_status KEY_A)" = "0" ]
  [[ "$(awk -F, '$1=="KEY_A"{print $3}' "$ATST_ALERT_STATUS_FILE")" =~ ^[0-9]+$ ]]
}

@test "A4: 80 parallel updates leave 41 lines without duplicate keys" {
  local n
  atst_test_source_common
  for n in $(seq 1 40); do
    atst_set_alert_status "K_$n" 1 3>&- &
    atst_set_alert_status SHARED "$n" 3>&- &
  done
  wait
  [ "$(wc -l < "$ATST_ALERT_STATUS_FILE")" -eq 41 ]
  [ "$(cut -d, -f1 "$ATST_ALERT_STATUS_FILE" | sort | uniq -d | wc -l)" -eq 0 ]
  [ "$(grep -c '^SHARED,' "$ATST_ALERT_STATUS_FILE")" -eq 1 ]
}

# Runs atst_set_alert_status K 1 from an empty working directory with "X,9,9" on stdin, and checks
# that it returns 1 with a message, leaves stdin unread and creates no file (#110).
set_fails_cleanly() {
  local out
  mkdir "$ATST_TEST_SANDBOX/cwd"
  cd "$ATST_TEST_SANDBOX/cwd"
  out=$(printf 'X,9,9\n' | { atst_set_alert_status K 1 2>"$ATST_TEST_SANDBOX/err"; echo "rc=$?"; cat; })
  [ "$out" = $'rc=1\nX,9,9' ]
  grep -q 'ATST_ALERT_STATUS_FILE is empty' "$ATST_TEST_SANDBOX/err"
  [ -z "$(ls -A)" ]
  [ -z "$(compgen -G "$HOME/.atst/alert_status*")" ]
}

@test "A5: an empty ATST_ALERT_STATUS_FILE makes atst_set_alert_status fail without reading stdin or creating files (#110)" {
  atst_test_set_config ATST_ALERT_STATUS_FILE ''
  atst_test_source_common
  [ -z "$ATST_ALERT_STATUS_FILE" ]
  set_fails_cleanly
}

@test "A6: with a syntax error before ATST_ALERT_STATUS_FILE in the config, set fails cleanly and get returns the default (#110)" {
  mkdir -p "$HOME/.atst"
  { echo 'X=("unclosed'; cat "$BATS_TEST_DIRNAME/../templates/config"; } > "$HOME/.atst/config"
  unset ATST_ALERT_STATUS_FILE
  atst_test_source_common 2>/dev/null
  [ -z "${ATST_ALERT_STATUS_FILE-}" ]
  set_fails_cleanly
  [ "$(atst_get_alert_status K 9 </dev/null)" = 9 ]
  [ -z "$(ls -A)" ]
  [ -z "$(compgen -G "$HOME/.atst/alert_status*")" ]
}
