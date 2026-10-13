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
