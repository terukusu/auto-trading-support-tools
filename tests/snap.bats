#!/usr/bin/env bats
# snap.sh (#148): takes one picture of the VNC desktop (:1) into ~/.atst/snap/ and prints its path.
# vncsnapshot is a stub made in the sandbox (the real one and the VNC desktop are never touched);
# LINE / ImgBB go to the curl stub. The ImgBB key, the LINE token / ID and the VNC password used here
# are dummy strings.

load test_helper

setup() {
  atst_test_setup_sandbox
  # a value in the developer's environment must not leak in (the config is the input)
  unset ATST_IMAGE_REPORT_DESKTOP ATST_IMGBB_EXPIRATION ATST_SNAP_KEEP
  mkdir -p "$ATST_TEST_SANDBOX/bin"
  PATH="$ATST_TEST_SANDBOX/bin:$PATH"
  export PATH
  SNAP="$BATS_TEST_DIRNAME/../snap.sh"
  SNAP_DIR="$HOME/.atst/snap"
}

teardown() {
  atst_test_teardown_sandbox
}

IMGBB_OK='{"data":{"id":"x","url_viewer":"https:\/\/ibb.co\/x","url":"https:\/\/i.ibb.co\/x\/a.png","display_url":"https:\/\/i.ibb.co\/x\/b.png"},"success":true,"status":200}'

# make_vnc_stub [ok|fail|empty]: records the call with its arguments in calls.log.
# ok writes a fake image to its last argument, fail writes nothing and exits 1, empty writes 0 bytes.
make_vnc_stub() {
  local mode="${1:-ok}" body
  case "$mode" in
    ok) body='printf JPG > "$last"' ;;
    fail) body='exit 1' ;;
    empty) body=': > "$last"' ;;
  esac
  cat > "$ATST_TEST_SANDBOX/bin/vncsnapshot" <<EOF
#!/bin/bash
{ printf vncsnapshot; for a in "\$@"; do printf ' [%s]' "\$a"; done; echo; } >> "$ATST_TEST_SANDBOX/calls.log"
for last in "\$@"; do :; done
$body
EOF
  chmod 755 "$ATST_TEST_SANDBOX/bin/vncsnapshot"
}

make_passwd() {
  mkdir -p "$HOME/.vnc"
  printf 'dummyvncpw\n' > "$HOME/.vnc/passwd"
  chmod 600 "$HOME/.vnc/passwd"
}

set_imgbb_key() {
  mkdir -p "$HOME/.atst"
  printf 'secretkey123\n' > "$HOME/.atst/.imgbb_key"
  chmod 600 "$HOME/.atst/.imgbb_key"
}

# Every command on PATH except the given names, linked into $ATST_TEST_SANDBOX/minbin.
# Run with PATH="$BATS_TEST_DIRNAME/stubs:$ATST_TEST_SANDBOX/minbin".
make_minbin() {
  local d name args=()
  local minbin="$ATST_TEST_SANDBOX/minbin"
  mkdir -p "$minbin"
  for name in "$@"; do
    args+=(! -name "$name")
  done
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    find "$d" -mindepth 1 -maxdepth 1 "${args[@]}" -exec ln -s -t "$minbin" {} + 2>/dev/null || true
  done
}

# jpg_count: the number of files in ~/.atst/snap/ named like a snap (any size).
jpg_count() {
  local n=0 f
  for f in "$SNAP_DIR"/*.jpg; do
    [ -e "$f" ] || continue
    [[ "${f##*/}" =~ ^[0-9]{8}-[0-9]{6}\.jpg$ ]] && n=$((n + 1))
  done
  echo "$n"
}

# new_jpgs: the snap files that are not the 2020 fixtures.
new_jpgs() {
  local f
  for f in "$SNAP_DIR"/*.jpg; do
    [ -e "$f" ] || continue
    case "${f##*/}" in
      2020*) ;;
      *) printf '%s\n' "$f" ;;
    esac
  done
}

imgbb_count() {
  if [ -e "$ATST_TEST_CURL_LOG" ]; then
    grep -c 'api.imgbb.com/1/upload' "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

last_payload() {
  local line
  line=$(grep 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG" | tail -1)
  printf '%s\n' "${line#* -d }"
}

image_count() {
  printf '%s\n' "$1" | grep -o '"type":"image"' | wc -l
}

# curl_log_empty: true when the curl stub was never called.
curl_log_empty() {
  [ ! -s "$ATST_TEST_CURL_LOG" ]
}

setup_line_ok() {
  make_vnc_stub ok
  make_passwd
  set_imgbb_key
  atst_test_set_config ATST_LINE_TOKEN dummytok148
  atst_test_set_config ATST_LINE_ID dummyid148
  export ATST_TEST_CURL_BODY="$IMGBB_OK"
}

# 20200101-000001.jpg .. 20200101-000012.jpg, keep.txt and sub/ in ~/.atst/snap/.
make_old12() {
  local i
  mkdir -p "$SNAP_DIR/sub"
  chmod 700 "$SNAP_DIR"
  for i in $(seq -w 1 12); do
    printf OLD > "$SNAP_DIR/20200101-0000$i.jpg"
  done
  printf keep > "$SNAP_DIR/keep.txt"
}

@test "SN-01 (AC-5, AC-12): saves one jpg (600, dir 700), prints only its path, calls vncsnapshot as report_image.sh does" {
  local f line
  make_vnc_stub ok
  make_passwd
  run bash -c 'bash "$1" 2>/dev/null' _ "$SNAP"
  [ "$status" -eq 0 ]
  [ "$(jpg_count)" -eq 1 ]
  f=$(new_jpgs)
  [[ "${f##*/}" =~ ^[0-9]{8}-[0-9]{6}\.jpg$ ]]
  [ "$output" = "$f" ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(stat -c %a "$f")" = 600 ]
  [ "$(stat -c %a "$SNAP_DIR")" = 700 ]
  [ "$(grep -c '^vncsnapshot ' "$ATST_TEST_SANDBOX/calls.log")" -eq 1 ]
  line=$(grep '^vncsnapshot ' "$ATST_TEST_SANDBOX/calls.log")
  [[ "$line" == *"[-quiet] [-passwd] [$HOME/.vnc/passwd] [-quality] [75] [-nocursor] [:1] [$f]" ]]
  [ "$(atst_test_push_count)" -eq 0 ]
  curl_log_empty
}

@test "SN-02 (AC-6): --line without an ImgBB key: exit 2 before vncsnapshot, nothing sent" {
  make_vnc_stub ok
  make_passwd
  run bash "$SNAP" --line
  [ "$status" -eq 2 ]
  [[ "$output" == *'[error]'* ]]
  [[ "$output" == *'setup_imgbb.sh'* ]]
  [ ! -e "$ATST_TEST_SANDBOX/calls.log" ]
  [ "$(jpg_count)" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  curl_log_empty
}

@test "SN-03 (AC-7, AC-11): --line with a key: one ImgBB upload, one push with one image, the jpg is kept, no secret in the output" {
  local f p err
  setup_line_ok
  run bash -c 'bash "$1" --line 2>/dev/null' _ "$SNAP"
  [ "$status" -eq 0 ]
  f=$(new_jpgs)
  [ -n "$f" ]
  [ "$output" = "$f" ]
  [ "${#lines[@]}" -eq 1 ]
  [ -s "$f" ]
  [ "$(imgbb_count)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
  p=$(last_payload)
  [ "$(image_count "$p")" -eq 1 ]
  [[ "$p" == *'デスクトップ画像('* ]]

  # stderr only, in a second run
  rm -f "$ATST_TEST_CURL_LOG"
  run bash -c 'bash "$1" --line 2>&1 >/dev/null' _ "$SNAP"
  [ "$status" -eq 0 ]
  err=$output
  [[ "$err" == *'[notice]'* ]]
  [[ "$err" == *'口座'* ]]

  # stdout + stderr
  rm -f "$ATST_TEST_CURL_LOG"
  run bash "$SNAP" --line
  [ "$status" -eq 0 ]
  [[ "$output" != *secretkey123* ]]
  [[ "$output" != *dummytok148* ]]
  [[ "$output" != *dummyid148* ]]
  [[ "$output" != *dummyvncpw* ]]
  [ "$(grep -c secretkey123 "$ATST_TEST_CURL_LOG" || true)" -eq 0 ]
  [ "$(grep -c dummytok148 "$ATST_TEST_CURL_LOG" || true)" -eq 0 ]
}

@test "SN-04 (AC-7b): ATST_IMAGE_REPORT_DESKTOP is not looked at" {
  setup_line_ok
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 0
  run bash "$SNAP" --line
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 1 ]

  rm -f "$ATST_TEST_CURL_LOG"
  atst_test_set_config ATST_IMAGE_REPORT_DESKTOP 1
  run bash "$SNAP"
  [ "$status" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
  curl_log_empty
}

@test "SN-05 (AC-7c): --line with a failed push: exit 2, the jpg is kept and its path printed" {
  local f
  setup_line_ok
  export ATST_TEST_CURL_HTTP_CODE_SEQ="200 500"
  run bash -c 'bash "$1" --line 2>/dev/null' _ "$SNAP"
  [ "$status" -eq 2 ]
  f=$(new_jpgs)
  [ -n "$f" ]
  [ -s "$f" ]
  [ "$output" = "$f" ]
  [ "$(imgbb_count)" -eq 1 ]
  [ "$(atst_test_push_count)" -eq 1 ]
}

@test "SN-06 (AC-8): keeps 10 jpgs by default, removes the oldest, leaves other names and directories" {
  local i
  make_vnc_stub ok
  make_passwd
  make_old12
  run bash "$SNAP"
  [ "$status" -eq 0 ]
  [ "$(jpg_count)" -eq 10 ]
  [ -n "$(new_jpgs)" ]
  for i in 01 02 03; do
    [ ! -e "$SNAP_DIR/20200101-0000$i.jpg" ]
  done
  for i in 04 05 06 07 08 09 10 11 12; do
    [ -e "$SNAP_DIR/20200101-0000$i.jpg" ]
  done
  [ -f "$SNAP_DIR/keep.txt" ]
  [ -d "$SNAP_DIR/sub" ]
}

@test "SN-07 (AC-8): ATST_SNAP_KEEP=2 keeps 2; abc / 0 fall back to 10" {
  local v
  make_vnc_stub ok
  make_passwd
  make_old12
  atst_test_set_config ATST_SNAP_KEEP 2
  run bash "$SNAP"
  [ "$status" -eq 0 ]
  [ "$(jpg_count)" -eq 2 ]
  [ -n "$(new_jpgs)" ]
  [ -e "$SNAP_DIR/20200101-000012.jpg" ]

  for v in abc 0; do
    rm -rf "${SNAP_DIR:?}" "$HOME/.atst/config"
    make_old12
    atst_test_set_config ATST_SNAP_KEEP "$v"
    run bash "$SNAP"
    [ "$status" -eq 0 ]
    [ "$(jpg_count)" -eq 10 ]
    [ ! -e "$SNAP_DIR/20200101-000003.jpg" ]
    [ -e "$SNAP_DIR/20200101-000004.jpg" ]
  done
}

@test "SN-08 (AC-9): no vncsnapshot: exit 2 with [error], no jpg, no push" {
  make_passwd
  make_minbin vncsnapshot
  PATH="$BATS_TEST_DIRNAME/stubs:$ATST_TEST_SANDBOX/minbin" run bash "$SNAP"
  [ "$status" -eq 2 ]
  [[ "$output" == *'[error]'* ]]
  [[ "$output" == *'vncsnapshot'* ]]
  [ "$(jpg_count)" -eq 0 ]
  [ "$(atst_test_push_count)" -eq 0 ]
}

@test "SN-09 (AC-9b): vncsnapshot fails or writes 0 bytes: exit 2, nothing left; no ~/.vnc/passwd: exit 2 without calling it" {
  local mode
  make_passwd
  for mode in fail empty; do
    make_vnc_stub "$mode"
    run bash "$SNAP"
    [ "$status" -eq 2 ]
    [[ "$output" == *'[error]'* ]]
    [ "$(jpg_count)" -eq 0 ]
  done

  rm -f "$ATST_TEST_SANDBOX/calls.log" "$HOME/.vnc/passwd"
  make_vnc_stub ok
  run bash "$SNAP"
  [ "$status" -eq 2 ]
  [[ "$output" == *'[error]'* ]]
  [ ! -e "$ATST_TEST_SANDBOX/calls.log" ]
  [ "$(jpg_count)" -eq 0 ]
}

@test "SN-10 (AC-10): a wrong argument exits 1 with Usage on stderr; -h prints Usage on stdout" {
  local a
  make_vnc_stub ok
  make_passwd
  for a in --foo extra '--line extra' '-h extra'; do
    # shellcheck disable=SC2086  # split on purpose: '--line extra' is two arguments
    run bash -c 'bash "$@" 2>&1 >/dev/null' _ "$SNAP" $a
    [ "$status" -eq 1 ]
    [[ "$output" == *'Usage:'* ]]
    [ ! -e "$ATST_TEST_SANDBOX/calls.log" ]
    [ "$(jpg_count)" -eq 0 ]
    [ ! -e "$HOME/.atst/config" ]
  done

  run bash -c 'bash "$1" -h 2>/dev/null' _ "$SNAP"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage:'* ]]
  [[ "$output" == *'--line'* ]]
  [ ! -e "$ATST_TEST_SANDBOX/calls.log" ]
  [ ! -e "$HOME/.atst/config" ]
}

@test "SN-11: an existing snap directory keeps its mode; a symlinked one is refused" {
  local target
  make_vnc_stub ok
  make_passwd
  mkdir -p "$SNAP_DIR"
  chmod 750 "$SNAP_DIR"
  run bash "$SNAP"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$SNAP_DIR")" = 750 ]
  [ "$(jpg_count)" -eq 1 ]

  rm -rf "${SNAP_DIR:?}" "$ATST_TEST_SANDBOX/calls.log"
  target="$ATST_TEST_SANDBOX/elsewhere"
  mkdir -p "$target"
  printf OLD > "$target/20200101-000001.jpg"
  ln -s "$target" "$SNAP_DIR"
  run bash "$SNAP"
  [ "$status" -eq 2 ]
  [[ "$output" == *'[error]'* ]]
  [ ! -e "$ATST_TEST_SANDBOX/calls.log" ]
  [ "$(find "$target" -mindepth 1 | wc -l)" -eq 1 ]
  [ -e "$target/20200101-000001.jpg" ]
}
