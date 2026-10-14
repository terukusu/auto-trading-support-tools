#!/usr/bin/env bats
# setup_cron.sh (#95 AC10): places the new template, points out old-style lines without removing
# them, never appends next to atst lines (jobs would run twice), changes nothing without an answer,
# and reports a failed write. crontab is a stub written into the sandbox; setup fails unless it is the
# crontab found first in PATH, so the real crontab is never touched.

load test_helper

LEGACY_CRONTAB='MAILTO=""
TARGET="('"'A'"')"
* * * * * sleep 10; wrapper.sh "$TARGET" check_order.sh
0 3 * * * /bin/true # mine'
OWN_CRONTAB='0 3 * * * /bin/true # mine'

setup() {
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  C="$ATST_TEST_SANDBOX/crontab"
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  # crontab -l prints the file (exit 1 without it); crontab / crontab - replace it with stdin
  # (exit 1 without writing when ATST_TEST_CRONTAB_FAIL is set); anything else is recorded as bad.
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
  } > "$ATST_TEST_SANDBOX/bin/crontab"
  chmod 755 "$ATST_TEST_SANDBOX/bin/crontab"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
  hash -r
  [ "$(command -v crontab)" = "$ATST_TEST_SANDBOX/bin/crontab" ]
  EXPECTED="$ATST_TEST_SANDBOX/expected"
  sed "s|%%ATST_HOME%%|$repo|" "$repo/templates/crontab.txt" > "$EXPECTED"
}

teardown() {
  atst_test_teardown_sandbox
}

# Number of crontab calls that would write (anything but -l).
write_calls() {
  if [ -e "$C.calls" ]; then
    grep -vc '^-l$' "$C.calls"
  else
    echo 0
  fi
}

@test "SC-1: an empty crontab gets the new template without a question" {
  run bash "$repo/setup_cron.sh" < /dev/null
  [ "$status" -eq 0 ]
  cmp "$C" "$EXPECTED"
  [ "$(grep -c '%%ATST_HOME%%' "$C")" -eq 0 ]
  [ "$(grep -c -e '^TARGET=' -e '\$TARGET' "$C")" -eq 0 ]
  [ "$(grep -cx '\* \* \* \* \* check_all\.sh' "$C")" -eq 1 ]
  [[ "$output" != *Overwrite* ]]
  [ ! -e "$C.bad" ]
}

@test "SC-2: old-style lines with n are pointed out and left unchanged (exit 1)" {
  printf '%s\n' "$LEGACY_CRONTAB" > "$C"
  cp "$C" "$ATST_TEST_SANDBOX/orig"
  run bash "$repo/setup_cron.sh" <<< n
  [ "$status" -eq 1 ]
  cmp "$C" "$ATST_TEST_SANDBOX/orig"
  [[ "$output" == *wrapper.sh* ]]
  [[ "$output" == *既存の\ crontab\ からの移行* ]]
  [[ "$output" == *"ATST_TARGETS=('A')"* ]]
  [ ! -e "$C.bad" ]
}

@test "SC-3: old-style lines with y or an empty line are pointed out and replaced by the template" {
  local a
  for a in y ''; do
    printf '%s\n' "$LEGACY_CRONTAB" > "$C"
    run bash "$repo/setup_cron.sh" <<< "$a"
    [ "$status" -eq 0 ] || { echo "answer=[$a]"; false; }
    [[ "$output" == *wrapper.sh* ]]
    cmp "$C" "$EXPECTED"
  done
  [ ! -e "$C.bad" ]
}

@test "SC-4: the new template already there with n is left unchanged, twice" {
  cp "$EXPECTED" "$C"
  run bash "$repo/setup_cron.sh" <<< n
  [ "$status" -eq 0 ]
  [[ "$output" == *登録済み* ]]
  cmp "$C" "$EXPECTED"
  run bash "$repo/setup_cron.sh" <<< n
  [ "$status" -eq 0 ]
  [[ "$output" == *登録済み* ]]
  cmp "$C" "$EXPECTED"
  [ "$(write_calls)" -eq 0 ]
  [ ! -e "$C.bad" ]
}

@test "SC-5: a crontab without atst lines with n gets the template appended" {
  printf '%s\n' "$OWN_CRONTAB" > "$C"
  cp "$C" "$ATST_TEST_SANDBOX/orig"
  run bash "$repo/setup_cron.sh" <<< n
  [ "$status" -eq 0 ]
  cmp "$C" <(cat "$ATST_TEST_SANDBOX/orig" "$EXPECTED")
  [ ! -e "$C.bad" ]
}

@test "SC-6: without ATST_TARGETS in the config it asks to write it" {
  mkdir -p "$HOME/.atst"
  cp "$repo/templates/config" "$HOME/.atst/config"
  sed -i '/^ATST_TARGETS=/d' "$HOME/.atst/config"
  run bash "$repo/setup_cron.sh" < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *ATST_TARGETS* ]]

  rm -f "$C"
  atst_test_set_targets A
  run bash "$repo/setup_cron.sh" < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *ATST_TARGETS* ]]
  [ ! -e "$C.bad" ]
}

@test "SC-7: no answer (stdin closed) leaves a non-empty crontab unchanged (exit 1)" {
  local c
  for c in "$LEGACY_CRONTAB" "$OWN_CRONTAB"; do
    rm -f "$C.calls"
    printf '%s\n' "$c" > "$C"
    cp "$C" "$ATST_TEST_SANDBOX/orig"
    run bash "$repo/setup_cron.sh" < /dev/null
    [ "$status" -eq 1 ]
    cmp "$C" "$ATST_TEST_SANDBOX/orig"
    [ "$(write_calls)" -eq 0 ]
  done
  [ ! -e "$C.bad" ]
}

@test "SC-8: a failed crontab write exits 2 with [error] and without done" {
  local l
  ATST_TEST_CRONTAB_FAIL=1
  export ATST_TEST_CRONTAB_FAIL
  run bash "$repo/setup_cron.sh" < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"[error]"* ]]
  for l in "${lines[@]}"; do
    [ "$l" != done ]
  done
  [ ! -e "$C.bad" ]
}

@test "SC-9: a path with & is written as it is into the PATH line" {
  local d="$ATST_TEST_SANDBOX/a&b"
  cp -Rp "$(atst_test_make_runner_home)" "$d"
  run bash "$d/setup_cron.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ "$(grep -cxF "PATH=\"$d:/bin:/usr/bin:/usr/local/bin\"" "$C")" -eq 1 ]
  [ ! -e "$C.bad" ]
}

@test "SC-10: the old TARGET value is shown as an ATST_TARGETS line, never run, the config left as it is" {
  mkdir -p "$HOME/.atst"
  cp "$repo/templates/config" "$HOME/.atst/config"
  cp "$HOME/.atst/config" "$ATST_TEST_SANDBOX/config.orig"
  printf '%s\n' 'TARGET="('"'"'B c'"'"' $(touch pwned))"' \
    '* * * * * sleep 10; wrapper.sh "$TARGET" check_order.sh' > "$C"
  cp "$C" "$ATST_TEST_SANDBOX/orig"
  cd "$ATST_TEST_SANDBOX"
  run bash "$repo/setup_cron.sh" <<< n
  [ "$status" -eq 1 ]
  [[ "$output" == *"ATST_TARGETS=('B c' \$(touch pwned))"* ]]
  [ ! -e "$ATST_TEST_SANDBOX/pwned" ]
  cmp "$C" "$ATST_TEST_SANDBOX/orig"
  cmp "$HOME/.atst/config" "$ATST_TEST_SANDBOX/config.orig"
  [ ! -e "$C.bad" ]
}
