#!/usr/bin/env bats
# #143/#176: the old-style crontab (TARGET and wrapper.sh "$TARGET" check_*.sh): its detection, the NG of
# doctor.sh, the 【注意】 line of check_daily.sh, and the backup and ATST_TARGETS append of setup_cron.sh.
# wrapper.sh was removed in #176, so the old-style lines do not run. crontab, apt and wine are stubs in
# $ATST_TEST_SANDBOX/bin put first on PATH; setup fails unless the crontab found first is the stub, so the
# real crontab is never touched.
# LINE goes to the curl stub. The TARGET value SecretA stands for a value that must not be printed.

load test_helper

LEGACY_CRONTAB='MAILTO=""
TARGET="('"'SecretA'"')"
* * * * * sleep 10; wrapper.sh "$TARGET" check_order.sh
0 3 * * * /bin/true # mine'
NEW_CRONTAB='* * * * * check_all.sh'
OWN_CRONTAB='0 3 * * * /bin/true # mine'
HB_U=https://example.invalid/ping/abcd9876

setup() {
  atst_test_setup_sandbox
  # the developer's environment must not leak in (the config is the input)
  unset ATST_TEST_CURL_HTTP_CODE_SEQ ATST_TEST_CURL_HTTP_CODE ATST_TEST_CURL_EXIT ATST_TEST_CURL_BODY \
    ATST_DAILY_REPORT ATST_HEARTBEAT_URL ATST_IMAGE_REPORT_DESKTOP ATST_TEST_CRONTAB_FAIL
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  C="$ATST_TEST_SANDBOX/crontab"
  B="$ATST_TEST_SANDBOX/bin"
  mkdir -p "$B"
  # The same crontab stub as tests/setup_cron.bats: crontab -l prints the file (exit 1 without it);
  # crontab / crontab - replace it with stdin (exit 1 without writing when ATST_TEST_CRONTAB_FAIL is
  # set); anything else is recorded as bad.
  {
    printf '#!/bin/bash\n'
    printf 'f=%q\n' "$C"
    cat <<'EOS'
printf '%s\n' "$*" >> "$f.calls"
case "$*" in
  -l)
    [ -e "$f" ] || exit 1
    cat "$f"
    ;;
  ''|-)
    if [ -n "${ATST_TEST_CRONTAB_FAIL:-}" ]; then
      cat > /dev/null
      exit 1
    fi
    t=$(mktemp "$f.XXXXXX") && cat > "$t" && mv "$t" "$f"
    ;;
  *)
    printf '%s\n' "$*" >> "$f.bad"
    exit 2
    ;;
esac
EOS
  } > "$B/crontab"
  chmod 755 "$B/crontab"
  atst_test_stub_script "$B" apt record
  atst_test_stub_script "$B" wine record
  PATH="$B:$PATH"
  export PATH
  hash -r
  [ "$(command -v crontab)" = "$B/crontab" ]
  EXPECTED="$ATST_TEST_SANDBOX/expected"
  sed "s|%%ATST_HOME%%|$repo|" "$repo/templates/crontab.txt" > "$EXPECTED"
}

teardown() {
  # LD-15 / LD-22 take permissions away; give them back so the sandbox can be removed.
  chmod -R u+rwX "$ATST_TEST_SANDBOX" 2>/dev/null
  atst_test_teardown_sandbox
}

# The config from the template with ATST_DAILY_REPORT=<0|1> (ATST_IMAGE_REPORT_DESKTOP is set, so the
# #135 notice does not come in).
daily_config() {
  atst_test_set_config ATST_DAILY_REPORT "$1"
}

run_daily() {
  run bash "$repo/check_daily.sh"
}

# The LINE pushes of the curl log (empty without it).
pushes() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG"
  fi
}

# Number of pushes carrying crontab.bak (the 【注意】 line of a report, or the one-time notice of
# earlier versions).
notice_pushes() {
  pushes | grep -c 'crontab\.bak'
}

# The pushes of the morning report.
report_pushes() {
  pushes | grep '稼働OK'
}

# Number of CRONTAB_LEGACY_NOTICE lines in alert_status (0 without the file). Nothing writes the key
# since #176.
recorded_notice() {
  if [ -e "$HOME/.atst/alert_status" ]; then
    grep -c '^CRONTAB_LEGACY_NOTICE,' "$HOME/.atst/alert_status"
  else
    echo 0
  fi
}

# Number of crontab calls that would write (anything but -l).
write_calls() {
  if [ -e "$C.calls" ]; then
    grep -vc '^-l$' "$C.calls"
  else
    echo 0
  fi
}

# The backups of setup_cron.sh, one per line.
backups() {
  find "$HOME/.atst" -maxdepth 1 -name 'crontab.bak.*' 2>/dev/null | sort
}

backup_count() {
  backups | grep -c .
}

run_setup_cron() {
  run bash "$repo/setup_cron.sh" <<< "$1"
}

# ---- what was removed (#176) ----

@test "LD-1: no deadline and no one-time notice are left in the scripts or README, and no wrapper.sh" {
  local w
  for w in ATST_LEGACY_CRONTAB_DEADLINE atst_legacy_crontab_expired CRONTAB_LEGACY_NOTICE 2027-05-31; do
    [ "$(cat "$repo"/*.sh "$repo"/lib/*.sh | grep -c -- "$w")" -eq 0 ] || { echo "$w"; false; }
  done
  [ "$(grep -c '2027-05-31' "$repo/README.md")" -eq 0 ]
  [ ! -e "$repo/wrapper.sh" ]
}

@test "LD-3: atst_crontab_form prints one word and never the crontab (AC3)" {
  local form want
  form() {
    run bash -c '. "$1/common.sh"; atst_crontab_form' _ "$repo"
  }
  printf '%s\n' "$NEW_CRONTAB" > "$C"; form
  [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ]; [ "$output" = new ]
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"; form
  [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ]; [ "$output" = legacy ]
  printf '%s\n%s\n' "$LEGACY_CRONTAB" "$NEW_CRONTAB" > "$C"; form
  [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ]; [ "$output" = mixed ]
  printf '# * * * * * check_all.sh\n  # wrapper.sh "$TARGET" check_order.sh\n' > "$C"; form
  [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ]; [ "$output" = none ]
  : > "$C"; form
  [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ]; [ "$output" = none ]
  rm -f "$C"; form
  [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ]; [ "$output" = unknown ]
  # the pure form of the same judgement
  atst_test_source_common
  for want in new legacy; do
    if [ "$want" = new ]; then form=$NEW_CRONTAB; else form=$LEGACY_CRONTAB; fi
    run atst_crontab_form_of "$form"
    [ "$output" = "$want" ]
    [[ "$output" != *SecretA* ]]
  done
  [ ! -e "$C.bad" ]
}

# ---- doctor.sh item 7 ----

@test "LD-4: doctor.sh: an old-style crontab is NG, the new format is OK (AC4)" {
  local l
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run bash "$repo/doctor.sh"
  [ "$status" -eq 1 ]
  l=$(printf '%s\n' "$output" | grep '^NG crontab -l 旧形式')
  [ "$(printf '%s\n' "$l" | grep -c .)" -eq 1 ]
  [[ "$l" == *setup_cron.sh* ]]
  [[ "$l" != *2027* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^OK crontab -l')" -eq 0 ]
  [[ "$output" != *SecretA* ]]

  printf '%s\n' "$NEW_CRONTAB" > "$C"
  run bash "$repo/doctor.sh"
  [ "$(printf '%s\n' "$output" | grep -cx 'OK crontab -l new format (check_all\.sh)')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^NG crontab -l')" -eq 0 ]
}

# ---- check_daily.sh ----

@test "LD-5: with the report: a 【注意】 line in each report, no separate notice, nothing recorded (AC5)" {
  daily_config 1
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run_daily
  [ "$status" -eq 0 ]
  run_daily
  [ "$status" -eq 0 ]
  [ "$(pushes | grep -c .)" -eq 2 ]
  [ "$(report_pushes | grep -c .)" -eq 2 ]
  [ "$(report_pushes | grep -c '【注意】crontab が旧形式 (wrapper.sh) です。wrapper.sh は撤去したため、旧形式の行は動きません。setup_cron.sh で移行してください')" -eq 2 ]
  # crontab.bak is only in the reports (no one-time notice of its own)
  [ "$(notice_pushes)" -eq 2 ]
  [ "$(pushes | grep 'crontab\.bak' | grep -vc '稼働OK')" -eq 0 ]
  [ "$(recorded_notice)" -eq 0 ]
  [ -z "$(pushes | grep -e SecretA -e 2027)" ]
}

@test "LD-6: without the report (ATST_DAILY_REPORT=0) the 【注意】 line still sends one push a day (AC6)" {
  local p
  daily_config 0
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run_daily
  [ "$status" -eq 0 ]
  run_daily
  [ "$status" -eq 0 ]
  [ "$(pushes | grep -c .)" -eq 2 ]
  [ "$(report_pushes | grep -c .)" -eq 2 ]
  p=$(pushes)
  [ "$(printf '%s\n' "$p" | grep -c '【注意】crontab が旧形式 (wrapper.sh) です')" -eq 2 ]
  [ "$(printf '%s\n' "$p" | grep -c 'setup_cron.sh')" -eq 2 ]
  [[ "$p" != *'1 度だけ'* ]]
  [[ "$p" != *SecretA* ]]
  [ "$(recorded_notice)" -eq 0 ]
}

@test "LD-9: a mixed crontab says 混在, also without the report (AC6)" {
  local p
  daily_config 1
  printf '%s\n%s\n' "$LEGACY_CRONTAB" "$NEW_CRONTAB" > "$C"
  run_daily
  [ "$status" -eq 0 ]
  [ "$(report_pushes | grep -c '【注意】crontab が旧形式と新形式の混在 (wrapper.sh) です')" -eq 1 ]
  rm -f "$ATST_TEST_CURL_LOG"
  daily_config 0
  run_daily
  [ "$status" -eq 0 ]
  p=$(pushes)
  [ "$(printf '%s\n' "$p" | grep -c .)" -eq 1 ]
  [[ "$p" == *'【注意】crontab が旧形式と新形式の混在 (wrapper.sh) です'* ]]
  [ "$(recorded_notice)" -eq 0 ]
}

@test "LD-10: new format, no crontab or an empty one: no line, no notice, nothing recorded (AC7)" {
  local kind
  daily_config 1
  for kind in new missing empty; do
    case "$kind" in
      new) printf '%s\n' "$NEW_CRONTAB" > "$C" ;;
      missing) rm -f "$C" ;;
      empty) : > "$C" ;;
    esac
    rm -f "$ATST_TEST_CURL_LOG"
    run_daily
    [ "$status" -eq 0 ] || { echo "$kind"; false; }
    [ "$(report_pushes | grep -c .)" -eq 1 ] || { echo "$kind"; false; }
    [ -z "$(pushes | grep -e 'crontab:' -e '【注意】crontab')" ] || { echo "$kind"; false; }
    [ "$(notice_pushes)" -eq 0 ] || { echo "$kind"; false; }
    [ "$(recorded_notice)" -eq 0 ] || { echo "$kind"; false; }
  done
}

# ---- heartbeat.sh ----

@test "LD-11: a CRONTAB_LEGACY_NOTICE line left by an earlier version gives a ping, not /fail (AC8)" {
  atst_test_set_config ATST_HEARTBEAT_URL "$HB_U"
  printf 'CRONTAB_LEGACY_NOTICE,1,%s\n' "$(date +%s)" > "$HOME/.atst/alert_status"
  run bash "$repo/heartbeat.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'abcd9876/fail"' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(grep 'abcd9876' "$ATST_TEST_CURL_LOG" | grep -vc '/fail')" -eq 1 ]
}

# ---- setup_cron.sh: the backup ----

@test "LD-12: Y on an old-style crontab saves it (600, same content) and writes the template (AC9)" {
  local bak
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  cp "$C" "$ATST_TEST_SANDBOX/orig"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  cmp "$C" "$EXPECTED"
  [ "$(backup_count)" -eq 1 ]
  bak=$(backups)
  [[ "$bak" =~ /crontab\.bak\.[0-9]{14}$ ]]
  [ "$(stat -c %a "$bak")" = 600 ]
  cmp "$bak" "$ATST_TEST_SANDBOX/orig"
  [[ "$output" == *"$bak"* ]]
  [[ "$output" == *撤去* ]]
  [[ "$output" != *2027* ]]
  [ ! -e "$C.bad" ]
}

@test "LD-13: n on a crontab of own lines appends the template and saves the crontab once (AC9)" {
  printf '%s\n' "$OWN_CRONTAB" > "$C"
  cp "$C" "$ATST_TEST_SANDBOX/orig"
  run_setup_cron n
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$C")" = "$OWN_CRONTAB" ]
  [ "$(backup_count)" -eq 1 ]
  cmp "$(backups)" "$ATST_TEST_SANDBOX/orig"
}

@test "LD-14: nothing is saved when the crontab is not changed or was empty (AC9)" {
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run_setup_cron n
  [ "$status" -eq 1 ]
  [ "$(backup_count)" -eq 0 ]

  printf '%s\n' "$NEW_CRONTAB" > "$C"
  run_setup_cron n
  [ "$status" -eq 0 ]
  [[ "$output" == *登録済み* ]]
  [ "$(backup_count)" -eq 0 ]

  rm -f "$C"
  run bash "$repo/setup_cron.sh" < /dev/null
  [ "$status" -eq 0 ]
  cmp "$C" "$EXPECTED"
  [ "$(backup_count)" -eq 0 ]
}

@test "LD-15: when the backup cannot be written the crontab is not changed (exit 2) (AC9)" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root can write to a directory of mode 500"
  fi
  atst_test_set_config ATST_DAILY_REPORT 1
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  cp "$C" "$ATST_TEST_SANDBOX/orig"
  chmod 500 "$HOME/.atst"
  run_setup_cron Y
  chmod 700 "$HOME/.atst"
  [ "$status" -eq 2 ]
  [[ "$output" == *'[error]'* ]]
  cmp "$C" "$ATST_TEST_SANDBOX/orig"
  [ "$(write_calls)" -eq 0 ]
  [ "$(backup_count)" -eq 0 ]
}

# ---- setup_cron.sh: ATST_TARGETS appended to the config ----

@test "LD-16: Y appends ATST_TARGETS once, readable by bash; a second Y appends nothing (AC10)" {
  local cfg="$HOME/.atst/config"
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_TARGETS=/d' "$cfg"
  printf '%s\n' 'TARGET="('"'A' 'B c'"')"' '* * * * * sleep 10; wrapper.sh "$TARGET" check_order.sh' > "$C"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$cfg")" = "ATST_TARGETS=('A' 'B c')" ]
  run bash -c '. "$1"; printf "%s\n" "${ATST_TARGETS[@]}"' _ "$cfg"
  [ "$output" = "A
B c" ]
  cmp "$C" "$EXPECTED"
  [ "$(backup_count)" -eq 1 ]

  printf '%s\n' 'TARGET="('"'A' 'B c'"')"' '* * * * * sleep 10; wrapper.sh "$TARGET" check_order.sh' > "$C"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [[ "$output" == *既にある* ]]
  [ "$(grep -c '^ATST_TARGETS=' "$cfg")" -eq 1 ]
  [ "$(backup_count)" -eq 2 ]
}

@test "LD-16b: the output of the first Y shows the appended line and done, without the ATST_TARGETS advice (AC10)" {
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_TARGETS=/d' "$HOME/.atst/config"
  printf '%s\n' 'TARGET="('"'A' 'B c'"')"' '* * * * * sleep 10; wrapper.sh "$TARGET" check_order.sh' > "$C"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [[ "$output" == *"追記しました: ATST_TARGETS=('A' 'B c')"* ]]
  [ "${lines[${#lines[@]}-1]}" = done ]
  [[ "$output" != *'[info] ~/.atst/config に ATST_TARGETS ('* ]]
}

@test "LD-17: a TARGET value out of the strict form is not appended nor run (AC10)" {
  local cfg="$HOME/.atst/config"
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_TARGETS=/d' "$cfg"
  printf '%s\n' 'TARGET="('"'B c'"' $(touch pwned))"' '* * * * * sleep 10; wrapper.sh "$TARGET" check_order.sh' > "$C"
  cd "$ATST_TEST_SANDBOX"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ATST_TARGETS=' "$cfg")" -eq 0 ]
  [ ! -e "$ATST_TEST_SANDBOX/pwned" ]
  [ ! -e "$HOME/pwned" ]
  [[ "$output" == *手で* ]]
  cmp "$C" "$EXPECTED"
}

@test "LD-17b: an empty TARGET element is not appended and the ATST_TARGETS advice still shows (AC10)" {
  local cfg="$HOME/.atst/config"
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_TARGETS=/d' "$cfg"
  printf '%s\n' "TARGET=\"('')\"" '* * * * * sleep 10; wrapper.sh "$TARGET" check_order.sh' > "$C"
  cd "$ATST_TEST_SANDBOX"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ATST_TARGETS=' "$cfg")" -eq 0 ]
  [[ "$output" == *手で* ]]
  cmp "$C" "$EXPECTED"
}

@test "LD-18: a config that already has ATST_TARGETS (the template) gets nothing appended (AC10)" {
  local cfg="$HOME/.atst/config"
  atst_test_set_config ATST_DAILY_REPORT 1
  cp "$cfg" "$ATST_TEST_SANDBOX/cfg.orig"
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  cmp "$cfg" "$ATST_TEST_SANDBOX/cfg.orig"
  [[ "$output" == *既にある* ]]
  cmp "$C" "$EXPECTED"
}

@test "LD-19: the appended line is a line of its own and atst_config_parse reads it (strict) (AC10)" {
  local cfg="$HOME/.atst/config"
  mkdir -p "$HOME/.atst"
  printf 'ATST_DAILY_REPORT=1' > "$cfg"
  printf '%s\n' 'TARGET="('"'A' 'B c'"')"' '* * * * * wrapper.sh "$TARGET" check_order.sh' > "$C"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$cfg")" -eq 2 ]
  [ "$(head -n 1 "$cfg")" = ATST_DAILY_REPORT=1 ]
  [ "$(tail -n 1 "$cfg")" = "ATST_TARGETS=('A' 'B c')" ]
  run bash -c '. "$1/common.sh"; atst_config_parse "$HOME/.atst/config" || exit 1
    printf "%s|%s\n" "$ATST_CONFIG_FORMAT" "${#ATST_TARGETS[@]}"; printf "%s\n" "${ATST_TARGETS[@]}"' _ "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "strict|2
A
B c" ]

  # "..." elements are taken as well
  printf 'ATST_DAILY_REPORT=1\n' > "$cfg"
  cat > "$C" <<'EOS'
TARGET="("X" 'Y z')"
* * * * * wrapper.sh "$TARGET" check_order.sh
EOS
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$cfg")" = "ATST_TARGETS=(\"X\" 'Y z')" ]
  run bash -c '. "$1/common.sh"; atst_config_parse "$HOME/.atst/config" || exit 1
    printf "%s|%s\n" "$ATST_CONFIG_FORMAT" "${#ATST_TARGETS[@]}"; printf "%s\n" "${ATST_TARGETS[@]}"' _ "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "strict|2
X
Y z" ]
}

@test "LD-20: two TARGET lines with different values are not appended (AC10)" {
  local cfg="$HOME/.atst/config"
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_TARGETS=/d' "$cfg"
  printf '%s\n' "TARGET=\"('A')\"" '* * * * * wrapper.sh "$TARGET" check_order.sh' \
    "TARGET=\"('B')\"" '* * * * * wrapper.sh "$TARGET" check_ping.sh' > "$C"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ATST_TARGETS=' "$cfg")" -eq 0 ]
  [[ "$output" == *手で* ]]
  cmp "$C" "$EXPECTED"
}

@test "LD-20b: two TARGET lines with the same value are appended once (AC10)" {
  local cfg="$HOME/.atst/config"
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_TARGETS=/d' "$cfg"
  printf '%s\n' "TARGET=\"('A')\"" '* * * * * wrapper.sh "$TARGET" check_order.sh' \
    "TARGET=\"('A')\"" '* * * * * wrapper.sh "$TARGET" check_ping.sh' > "$C"
  run_setup_cron Y
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ATST_TARGETS=' "$cfg")" -eq 1 ]
  [ "$(tail -n 1 "$cfg")" = "ATST_TARGETS=('A')" ]
}

@test "LD-22: when the append fails the crontab is not changed (exit 2)" {
  local cfg="$HOME/.atst/config"
  if [ "$(id -u)" -eq 0 ]; then
    skip "root can write to a file of mode 400"
  fi
  atst_test_set_config ATST_DAILY_REPORT 1
  sed -i '/^ATST_TARGETS=/d' "$cfg"
  chmod 400 "$cfg"
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  cp "$C" "$ATST_TEST_SANDBOX/orig"
  run_setup_cron Y
  chmod 600 "$cfg"
  [ "$status" -eq 2 ]
  [[ "$output" == *'[error]'* ]]
  cmp "$C" "$ATST_TEST_SANDBOX/orig"
  [ "$(write_calls)" -eq 0 ]
  [ "$(grep -c '^ATST_TARGETS=' "$cfg")" -eq 0 ]
}
