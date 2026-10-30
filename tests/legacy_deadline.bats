#!/usr/bin/env bats
# #143: the old-style crontab (TARGET and wrapper.sh "$TARGET" check_*.sh) works until a fixed deadline
# (ATST_LEGACY_CRONTAB_DEADLINE in common.sh) and after it. The deadline changes only what doctor.sh and
# check_daily.sh say. setup_cron.sh saves the crontab before writing it and appends ATST_TARGETS to the
# config when it can. crontab, date, apt and wine are stubs in $ATST_TEST_SANDBOX/bin put first on PATH;
# setup fails unless the crontab and date found first are the stubs, so the real crontab is never touched.
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
  atst_test_stub_date "$B" 2026-11-01
  PATH="$B:$PATH"
  export PATH
  hash -r
  [ "$(command -v crontab)" = "$B/crontab" ]
  [ "$(command -v date)" = "$B/date" ]
  [ "$(date +%Y-%m-%d)" = 2026-11-01 ]
  EXPECTED="$ATST_TEST_SANDBOX/expected"
  sed "s|%%ATST_HOME%%|$repo|" "$repo/templates/crontab.txt" > "$EXPECTED"
}

teardown() {
  # LD-15 / LD-22 take permissions away; give them back so the sandbox can be removed.
  chmod -R u+rwX "$ATST_TEST_SANDBOX" 2>/dev/null
  atst_test_teardown_sandbox
}

set_day() {
  atst_test_stub_date "$B" "$1"
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

# Number of pushes carrying the one-time notice.
notice_pushes() {
  pushes | grep -c 'crontab\.bak'
}

# The pushes of the morning report.
report_pushes() {
  pushes | grep '稼働OK'
}

# Number of CRONTAB_LEGACY_NOTICE lines in alert_status (0 without the file).
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

# ---- the constant and the two functions ----

@test "LD-1: the deadline is written once in the scripts and README shows the same date (AC1)" {
  [ "$(cat "$repo"/*.sh "$repo"/lib/*.sh | grep -c '2027-05-31')" -eq 1 ]
  [ "$(cat "$repo"/*.sh "$repo"/lib/*.sh | grep -c '^ATST_LEGACY_CRONTAB_DEADLINE=')" -eq 1 ]
  atst_test_source_common
  [[ "$ATST_LEGACY_CRONTAB_DEADLINE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  [ "$(grep -c "\*\*${ATST_LEGACY_CRONTAB_DEADLINE} まで\*\*" "$repo/README.md")" -ge 1 ]
}

@test "LD-2: atst_legacy_crontab_expired is true only after the deadline and prints nothing (AC2)" {
  local d want
  atst_test_source_common
  while IFS='|' read -r d want; do
    run atst_legacy_crontab_expired "$d"
    [ "$status" -eq "$want" ] || { echo "date=[$d] status=$status"; false; }
    [ -z "$output" ] || { echo "date=[$d] output=[$output]"; false; }
  done <<'EOS'
2027-05-31|1
2027-06-01|0
2026-11-01|1
|1
2027/06/01|1
tomorrow|1
2028-01-01|0
2027-06-01x|1
EOS
  run atst_legacy_crontab_expired
  [ "$status" -eq 1 ]
  [ -z "$output" ]
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

@test "LD-4: doctor.sh: old-style OK before the deadline, NG after it; new format OK on both days (AC4)" {
  local ng_before ng_after l
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run bash "$repo/doctor.sh"
  l=$(printf '%s\n' "$output" | grep '^OK crontab -l 旧形式')
  [ "$(printf '%s\n' "$l" | grep -c .)" -eq 1 ]
  [[ "$l" == *2027-05-31*setup_cron.sh* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^NG crontab -l')" -eq 0 ]
  ng_before=$(printf '%s\n' "$output" | grep -c '^NG ')
  [[ "$output" != *SecretA* ]]

  set_day 2027-06-01
  run bash "$repo/doctor.sh"
  [ "$status" -eq 1 ]
  l=$(printf '%s\n' "$output" | grep '^NG crontab -l 旧形式')
  [ "$(printf '%s\n' "$l" | grep -c .)" -eq 1 ]
  [[ "$l" == *'猶予期限 2027-05-31'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^OK crontab -l')" -eq 0 ]
  ng_after=$(printf '%s\n' "$output" | grep -c '^NG ')
  [ "$ng_after" -eq $((ng_before + 1)) ]

  printf '%s\n' "$NEW_CRONTAB" > "$C"
  for l in 2026-11-01 2027-06-01; do
    set_day "$l"
    run bash "$repo/doctor.sh"
    [ "$(printf '%s\n' "$output" | grep -cx 'OK crontab -l new format (check_all\.sh)')" -eq 1 ]
  done
}

# ---- check_daily.sh ----

@test "LD-5: before the deadline with the report: a line in each report and the notice once (AC5)" {
  daily_config 1
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run_daily
  [ "$status" -eq 0 ]
  run_daily
  [ "$status" -eq 0 ]
  [ "$(pushes | grep -c .)" -eq 3 ]
  [ "$(report_pushes | grep -c .)" -eq 2 ]
  [ "$(report_pushes | grep -c 'crontab: 旧形式 (wrapper.sh) です。2027-05-31 までに setup_cron.sh で移行してください')" -eq 2 ]
  [ "$(notice_pushes)" -eq 1 ]
  [ "$(grep -c '^CRONTAB_LEGACY_NOTICE,1,[0-9]*$' "$HOME/.atst/alert_status")" -eq 1 ]
  [ -z "$(pushes | grep SecretA)" ]
}

@test "LD-6: before the deadline without the report: only the one-time notice is sent (AC5)" {
  local n
  daily_config 0
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run_daily
  [ "$status" -eq 0 ]
  run_daily
  [ "$status" -eq 0 ]
  [ "$(pushes | grep -c .)" -eq 1 ]
  [ "$(notice_pushes)" -eq 1 ]
  n=$(pushes)
  [[ "$n" == *'【お知らせ】crontab が旧形式 (wrapper.sh)'* ]]
  [[ "$n" == *2027-05-31* ]]
  [[ "$n" == *setup_cron.sh* ]]
  [[ "$n" == *crontab.bak* ]]
  [[ "$n" == *'1 度だけ'* ]]
  [[ "$n" != *'crontab: '* ]]
  [[ "$n" != *SecretA* ]]
  [ "$(recorded_notice)" -eq 1 ]
}

@test "LD-7: a failed notice push is not recorded and is sent again on the next run (AC5)" {
  local c1
  daily_config 1
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  # curl calls: quota x2, daily push, notice push (500)
  export ATST_TEST_CURL_HTTP_CODE_SEQ="200 200 200 500"
  run_daily
  unset ATST_TEST_CURL_HTTP_CODE_SEQ
  [ "$(recorded_notice)" -eq 0 ]
  grep -q 'http=500' "$HOME/.atst/line_error.log"
  c1=$(notice_pushes)
  [ "$c1" -eq 1 ]
  run_daily
  [ "$status" -eq 0 ]
  [ "$(notice_pushes)" -eq $((c1 + 1)) ]
  [ "$(recorded_notice)" -eq 1 ]
  grep -q '^CRONTAB_LEGACY_NOTICE,1,' "$HOME/.atst/alert_status"
}

@test "LD-8: after the deadline: a warning line that sends the report every day and no notice (AC6)" {
  local p
  set_day 2027-06-01
  daily_config 0
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  run_daily
  [ "$status" -eq 0 ]
  run_daily
  [ "$status" -eq 0 ]
  [ "$(pushes | grep -c .)" -eq 2 ]
  [ "$(report_pushes | grep -c .)" -eq 2 ]
  p=$(pushes)
  [ "$(printf '%s\n' "$p" | grep -c '【注意】crontab の旧形式 (wrapper.sh) の猶予期限 2027-05-31 を過ぎています')" -eq 2 ]
  [ "$(printf '%s\n' "$p" | grep -c '監視は止まっていません')" -eq 2 ]
  [ "$(notice_pushes)" -eq 0 ]
  [ "$(recorded_notice)" -eq 0 ]
}

@test "LD-9: a mixed crontab says 混在 before and after the deadline (AC6)" {
  local p
  daily_config 1
  printf '%s\n%s\n' "$LEGACY_CRONTAB" "$NEW_CRONTAB" > "$C"
  run_daily
  [ "$status" -eq 0 ]
  [ "$(report_pushes | grep -c 'crontab: 旧形式と新形式の混在 (wrapper.sh) です')" -eq 1 ]
  [ "$(notice_pushes)" -eq 1 ]
  [ "$(pushes | grep 'crontab\.bak' | grep -c '混在')" -eq 1 ]
  set_day 2027-06-01
  rm -f "$ATST_TEST_CURL_LOG"
  daily_config 0
  run_daily
  [ "$status" -eq 0 ]
  p=$(pushes)
  [ "$(printf '%s\n' "$p" | grep -c .)" -eq 1 ]
  [[ "$p" == *'【注意】crontab の旧形式と新形式の混在 (wrapper.sh) の猶予期限 2027-05-31'* ]]
}

@test "LD-10: new format, no crontab or an empty one: no line, no notice, nothing recorded (AC7)" {
  local kind day
  daily_config 1
  for kind in new missing empty; do
    for day in 2026-11-01 2027-06-01; do
      case "$kind" in
        new) printf '%s\n' "$NEW_CRONTAB" > "$C" ;;
        missing) rm -f "$C" ;;
        empty) : > "$C" ;;
      esac
      set_day "$day"
      rm -f "$ATST_TEST_CURL_LOG"
      run_daily
      [ "$status" -eq 0 ] || { echo "$kind $day"; false; }
      [ "$(report_pushes | grep -c .)" -eq 1 ] || { echo "$kind $day"; false; }
      [ -z "$(pushes | grep -e 'crontab:' -e '【注意】crontab')" ] || { echo "$kind $day"; false; }
      [ "$(notice_pushes)" -eq 0 ] || { echo "$kind $day"; false; }
      [ "$(recorded_notice)" -eq 0 ] || { echo "$kind $day"; false; }
    done
  done
}

# ---- heartbeat.sh ----

@test "LD-11: CRONTAB_LEGACY_NOTICE,1 alone gives a ping, not /fail (AC8)" {
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
  [[ "$output" == *2027-05-31* ]]
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

# ---- where the deadline is read ----

@test "LD-21: only doctor.sh and check_daily.sh call atst_legacy_crontab_expired, once each (AC12)" {
  local f n
  [ "$(grep -c 'atst_legacy_crontab_expired' "$repo/doctor.sh")" -eq 1 ]
  [ "$(grep -c 'atst_legacy_crontab_expired' "$repo/check_daily.sh")" -eq 1 ]
  for f in "$repo"/*.sh "$repo"/lib/*.sh; do
    case "${f##*/}" in
      common.sh|doctor.sh|check_daily.sh) continue ;;
    esac
    n=$(grep -c 'atst_legacy_crontab_expired' "$f" || :)
    [ "$n" -eq 0 ] || { echo "$f"; false; }
  done
}
