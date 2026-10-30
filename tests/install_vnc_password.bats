#!/usr/bin/env bats
# The VNC password of install_required_for_mt.sh (#146), without running the installer:
# - generate_vnc_password / vnc_password_ok come from sourcing it with ATST_INSTALL_SOURCE_ONLY=1
#   (VP, IG-1); the guard works only when sourced (IG-2).
# - the top level that takes VNC_PASSWORD runs from head.sh, a copy cut before TARGET_LOCALE= (so no
#   trap, apt, sudo or /etc/os-release can be reached; IG-6 checks that) with a probe at the end (IG).
# - setup_vncserver / verify_and_report are cut out with sed and run with mocks (SV, VR).
# vncpasswd, sudo, systemctl and ss are stubs written into the sandbox; setup fails unless they are the
# commands found first in PATH, so no real vncpasswd / sudo runs. The passwords are fixed dummies.

load test_helper

setup() {
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  I="$repo/install_required_for_mt.sh"
  B="$ATST_TEST_SANDBOX/bin"
  mkdir -p "$B"

  # vncpasswd: records its arguments, stdin, the mode of the file its stdout goes to and whether
  # VNC_PASSWORD reached it; ATST_TEST_VNCPASSWD_MODE: (default) 8 bytes and exit 0, fail = nothing
  # and exit 1, empty = nothing and exit 0, missing = exit 127. It never prints the password.
  cat > "$B/vncpasswd" <<'EOS'
#!/bin/bash
d="$ATST_TEST_SANDBOX"
printf '%s\n' "$*" >> "$d/vncpasswd.args"
cat > "$d/vncpasswd.stdin"
stat -L -c %a "/proc/$$/fd/1" > "$d/vncpasswd.mode" 2>/dev/null
[ -n "${VNC_PASSWORD+x}" ] && echo leaked >> "$d/vncpasswd.env"
case "${ATST_TEST_VNCPASSWD_MODE:-}" in
  fail) exit 1 ;;
  empty) exit 0 ;;
  missing) exit 127 ;;
esac
printf 'ENCPASS!'
EOS
  cat > "$B/ss" <<'EOS'
#!/bin/bash
echo "State  Recv-Q Send-Q Local Address:Port Peer Address:Port"
for p in ${ATST_TEST_SS_PORTS:-}; do
  echo "LISTEN 0      128    127.0.0.1:$p   0.0.0.0:*"
done
EOS
  chmod 755 "$B/vncpasswd" "$B/ss"
  atst_test_stub_script "$B" sudo record
  atst_test_stub_script "$B" systemctl record
  PATH="$B:$PATH"
  export PATH
  hash -r
  local c
  for c in vncpasswd ss sudo systemctl; do
    [ "$(command -v "$c")" = "$B/$c" ]
  done

  # The two functions, cut out (a failed cut must not pass as an empty success).
  FN="$ATST_TEST_SANDBOX/fn.sh"
  { sed -n '/^function setup_vncserver/,/^}/p' "$I"; sed -n '/^function verify_and_report/,/^}/p' "$I"; } > "$FN"
  [ "$(grep -c '^function ' "$FN")" -eq 2 ]
  grep -q 'vncpasswd -f' "$FN"

  # What the two functions need from the rest of the installer.
  MOCKS="$ATST_TEST_SANDBOX/mocks.sh"
  cat > "$MOCKS" <<EOS
IS_SYSTEMD=
DIR_TEMPLATES=$(printf '%q' "$repo/templates")
ORG_USER=tester
TMPDIR=$(printf '%q' "$ATST_TEST_SANDBOX")
INSTALLER_STATUS=running
wine() { echo wine-10.0; }
wineprefix_ok() { return 0; }
wineprefix_arch() { echo win64; }
ensure_sshd_alive() { return 0; }
reboot_required_reason() { :; }
EOS

  # The top level down to TARGET_LOCALE=, with a probe at the end.
  HEAD="$ATST_TEST_SANDBOX/head.sh"
  sed '/^TARGET_LOCALE=/,$d' "$I" > "$HEAD"
  cat >> "$HEAD" <<'EOS'
echo REACHED
[ -z "${VNC_PASSWORD+x}" ] && echo env-unset
[ "${VNC_PASS_GIVEN-}" = "${ATST_TEST_EXPECT-}" ] && echo given-match
case "$(declare -p VNC_PASS_GIVEN 2>/dev/null)" in "declare -x"*) echo exported ;; esac
bash -c 'echo "child:${VNC_PASSWORD+x}${VNC_PASS_GIVEN+y}"'
EOS
}

teardown() {
  atst_test_teardown_sandbox
}

# fn <commands>: runs <commands> after sourcing the functions of the installer, fn.sh and the mocks.
fn() {
  run bash -c 'umask 022; ATST_INSTALL_SOURCE_ONLY=1 . "$1" && . "$2" && . "$3" && eval "$4"' \
    _ "$I" "$FN" "$MOCKS" "$1"
}
# src <commands> [<value>]: runs <commands> after sourcing only the installer; <value> is "$2" there.
src() {
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1" && eval "$3"' _ "$I" "${2-}" "$1"
}

# --- C3 generate_vnc_password -------------------------------------------------------------------

@test "VP-1: generate_vnc_password prints one line of 8 letters/digits and nothing on stderr" {
  src 'generate_vnc_password 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" =~ ^[A-Za-z0-9]{8}$ ]] || false
  src 'generate_vnc_password 2>&1 >/dev/null'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "VP-2: two calls give different values" {
  src 'a=$(generate_vnc_password) && b=$(generate_vnc_password) && if [ "$a" = "$b" ]; then echo same; else echo diff; fi'
  [ "$status" -eq 0 ]
  [ "$output" = diff ]
}

@test "VP-3: works under set -e -o pipefail" {
  src 'set -e -o pipefail; p=$(generate_vnc_password); [[ $p =~ ^[A-Za-z0-9]{8}$ ]] && echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "VP-4: returns 1 and prints nothing when no random letters come" {
  src 'tr() { return 1; }; generate_vnc_password; echo "rc=$?"'
  [ "$output" = 'rc=1' ]
}

# --- C4 vnc_password_ok -------------------------------------------------------------------------

@test "VP-5 / VP-7: vnc_password_ok accepts 6 to 8 printable characters, silently" {
  local v
  for v in 'Abc123' 'Ab3$xY9!' 'abcdefgh' '!!!!!!'; do
    src 'vnc_password_ok "$2"' "$v"
    [ "$status" -eq 0 ] || { echo "rejected: $v"; false; }
    [ -z "$output" ]
  done
}

@test "VP-6 / VP-7: vnc_password_ok rejects other lengths, spaces, tabs, newlines and empty, silently" {
  local v
  for v in 'abc12' 'abcdefghi' 'ab c123' '' $'ab\tc123' $'abc\n123'; do
    src 'vnc_password_ok "$2"' "$v"
    [ "$status" -ne 0 ] || { echo "accepted: $v"; false; }
    [ -z "$output" ]
  done
}

# --- C5 source guard and VNC_PASSWORD -----------------------------------------------------------

@test "IG-1: sourcing with ATST_INSTALL_SOURCE_ONLY runs nothing of the top level" {
  find "$HOME" -mindepth 1 | sort > "$ATST_TEST_SANDBOX/before"
  run bash -c 'unset WINEPREFIX DEBIAN_FRONTEND; ATST_INSTALL_SOURCE_ONLY=1 . "$1" || exit 9
    declare -F generate_vnc_password vnc_password_ok
    echo "${ABS_PWD-u}${TARGET_LOCALE-u}${IS_SYSTEMD-u}${WINEPREFIX-u}${DEBIAN_FRONTEND-u}${VNC_PASS_GIVEN-u}"' _ "$I"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = generate_vnc_password ]
  [ "${lines[1]}" = vnc_password_ok ]
  [ "${lines[2]}" = uuuuuu ]
  find "$HOME" -mindepth 1 | sort > "$ATST_TEST_SANDBOX/after"
  diff "$ATST_TEST_SANDBOX/before" "$ATST_TEST_SANDBOX/after"
  [ ! -e "$ATST_TEST_SANDBOX/calls.log" ]
}

@test "IG-2: the guard works only when sourced, never when run" {
  run env ATST_INSTALL_SOURCE_ONLY=1 bash "$HEAD"
  [[ "$output" == *REACHED* ]] || false
  run bash -c '. "$1"; echo after' _ "$HEAD"
  [[ "$output" == *REACHED* ]] || false
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1"; echo after' _ "$HEAD"
  [[ "$output" != *REACHED* ]] || false
  [[ "$output" == *after* ]] || false
}

@test "IG-3: a wrong VNC_PASSWORD stops at once with exit 1, without showing it" {
  local v
  for v in 'abc12' 'abcdefghi' 'ab c123'; do
    run env VNC_PASSWORD="$v" bash "$HEAD"
    [ "$status" -eq 1 ] || { echo "rc $status: $v"; false; }
    [[ "$output" == *'VNC_PASSWORD must be 6 to 8 printable characters'* ]] || false
    [[ "$output" != *REACHED* ]] || false
    [[ "$output" != *"$v"* ]] || { echo "shown: $v"; false; }
  done
}

@test "IG-4: a valid VNC_PASSWORD is kept unexported and removed from the environment" {
  run env VNC_PASSWORD=Abc123 ATST_TEST_EXPECT=Abc123 bash "$HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *REACHED* ]] || false
  [[ "$output" == *env-unset* ]] || false
  [[ "$output" == *given-match* ]] || false
  [[ "$output" == *$'\n'child:* ]] || false
  [ "$(printf '%s\n' "$output" | grep -cx 'child:')" -eq 1 ]
  [[ "$output" != *exported* ]] || false
  [[ "$output" != *Abc123* ]] || false
}

@test "IG-5: no or an empty VNC_PASSWORD goes on" {
  run env -u VNC_PASSWORD ATST_TEST_EXPECT= bash "$HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *REACHED* ]] || false
  [[ "$output" == *given-match* ]] || false
  run env VNC_PASSWORD= ATST_TEST_EXPECT= bash "$HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *REACHED* ]] || false
  [[ "$output" == *given-match* ]] || false
}

@test "IG-6: VNC_PASSWORD is taken before the variables, the trap, apt, sudo and os-release" {
  [ "$(grep -c '^[^#]*unset VNC_PASSWORD' "$HEAD")" -eq 1 ]
  [ "$(grep -cE '^[^#]*(trap |apt-get|sudo |/etc/os-release)' "$HEAD")" -eq 0 ]
}

# --- C6 setup_vncserver -------------------------------------------------------------------------

@test "SV-1: a new ~/.vnc/passwd gets a generated password through stdin, 600 from the start" {
  fn 'IS_SYSTEMD=1; VNC_PASS_GIVEN=; setup_vncserver; echo "state=$VNC_PASS_STATE"
    [ "$VNC_PASS_GENERATED" = "$(cat "$ATST_TEST_SANDBOX/vncpasswd.stdin")" ] && echo match'
  [ "$status" -eq 0 ]
  [[ "$output" == *state=generated* ]] || false
  [[ "$output" == *match* ]] || false
  local v
  v=$(cat "$ATST_TEST_SANDBOX/vncpasswd.stdin")
  [[ "$v" =~ ^[A-Za-z0-9]{8}$ ]] || false
  [ "$(wc -l < "$ATST_TEST_SANDBOX/vncpasswd.stdin")" -eq 1 ]
  [ "$(cat "$ATST_TEST_SANDBOX/vncpasswd.args")" = '-f' ]
  [ "$(cat "$ATST_TEST_SANDBOX/vncpasswd.mode")" = 600 ]
  [ "$(stat -c %a "$HOME/.vnc/passwd")" = 600 ]
  [ "$(cat "$HOME/.vnc/passwd")" = 'ENCPASS!' ]
  [[ "$output" != *"$v"* ]] || false
  [ ! -e "$ATST_TEST_SANDBOX/vncpasswd.env" ]
}

@test "SV-2: VNC_PASSWORD is used for a new ~/.vnc/passwd and not shown" {
  fn 'IS_SYSTEMD=1; VNC_PASS_GIVEN=Abc123; setup_vncserver; echo "state=$VNC_PASS_STATE gen=[$VNC_PASS_GENERATED]"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'state=env gen=[]'* ]] || false
  [ "$(cat "$ATST_TEST_SANDBOX/vncpasswd.stdin")" = Abc123 ]
  [ "$(cat "$ATST_TEST_SANDBOX/vncpasswd.mode")" = 600 ]
  [ "$(stat -c %a "$HOME/.vnc/passwd")" = 600 ]
  [[ "$output" != *Abc123* ]] || false
}

@test "SV-3: an existing ~/.vnc/passwd is kept as it is" {
  mkdir -p "$HOME/.vnc"
  printf 'OLDPASS!' > "$HOME/.vnc/passwd"
  chmod 600 "$HOME/.vnc/passwd"
  cp -p "$HOME/.vnc/passwd" "$ATST_TEST_SANDBOX/old"
  fn 'IS_SYSTEMD=1; VNC_PASS_GIVEN=Abc123; setup_vncserver; echo "state=$VNC_PASS_STATE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *state=kept* ]] || false
  cmp "$HOME/.vnc/passwd" "$ATST_TEST_SANDBOX/old"
  [ "$(stat -c %a "$HOME/.vnc/passwd")" = 600 ]
  [ ! -e "$ATST_TEST_SANDBOX/vncpasswd.args" ]
}

@test "SV-4 / SV-5 / SV-6: a failed, empty or missing vncpasswd leaves no file and does not stop" {
  local m
  for m in fail empty missing; do
    rm -rf "$HOME/.vnc"
    export ATST_TEST_VNCPASSWD_MODE="$m"
    run bash -c 'umask 022; ATST_INSTALL_SOURCE_ONLY=1 . "$1" && . "$2" && . "$3" || exit 9
      IS_SYSTEMD=1; VNC_PASS_GIVEN=; setup_vncserver 2>"$ATST_TEST_SANDBOX/err"
      echo "rc=$? state=$VNC_PASS_STATE gen=[$VNC_PASS_GENERATED]"' _ "$I" "$FN" "$MOCKS"
    [ "$status" -eq 0 ] || { echo "$m: status $status"; false; }
    [[ "$output" == *'state=failed gen=[]'* ]] || { echo "$m: $output"; false; }
    [ ! -e "$HOME/.vnc/passwd" ] || { echo "$m: file left"; false; }
    grep -q '\[error\] could not set the VNC password' "$ATST_TEST_SANDBOX/err" || { echo "$m: no error"; false; }
  done 3>&-
  # (the loop sets ATST_TEST_VNCPASSWD_MODE through the environment below)
}

@test "SV-7: when no password can be generated, vncpasswd is not called with an empty one" {
  fn 'IS_SYSTEMD=1; VNC_PASS_GIVEN=; tr() { return 1; }; setup_vncserver 2>/dev/null; echo "state=$VNC_PASS_STATE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *state=failed* ]] || false
  [ ! -e "$HOME/.vnc/passwd" ]
  [ ! -e "$ATST_TEST_SANDBOX/vncpasswd.args" ]
}

@test "SV-8: a second run keeps the password made by the first (P2)" {
  fn 'IS_SYSTEMD=1; VNC_PASS_GIVEN=; setup_vncserver; echo "1=$VNC_PASS_STATE"
    cp -p "$HOME/.vnc/passwd" "$ATST_TEST_SANDBOX/first"
    setup_vncserver; echo "2=$VNC_PASS_STATE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *1=generated* ]] || false
  [[ "$output" == *2=kept* ]] || false
  cmp "$HOME/.vnc/passwd" "$ATST_TEST_SANDBOX/first"
  [ "$(wc -l < "$ATST_TEST_SANDBOX/vncpasswd.args")" -eq 1 ]
}

@test "SV-9: the old fixed password and its message are gone" {
  fn 'IS_SYSTEMD=1; VNC_PASS_GIVEN=; setup_vncserver'
  [ "$status" -eq 0 ]
  [[ "$output" != *123123* ]] || false
  [[ "$output" != *'Setting default password'* ]] || false
}

# --- C7 verify_and_report -----------------------------------------------------------------------

@test "VR-1: a generated password is shown once, on stdout" {
  fn 'VNC_PASS_STATE=generated; VNC_PASS_GENERATED=Zx9Qw2Lp; verify_and_report 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[ OK ] VNC password: Zx9Qw2Lp (generated now and shown only this once')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -oF Zx9Qw2Lp | wc -l)" -eq 1 ]
  fn 'VNC_PASS_STATE=generated; VNC_PASS_GENERATED=Zx9Qw2Lp; verify_and_report 2>&1 >/dev/null'
  [[ "$output" != *Zx9Qw2Lp* ]] || false
}

@test "VR-2: a password from VNC_PASSWORD is not shown" {
  fn 'VNC_PASS_STATE=env; VNC_PASS_GIVEN=Abc123; VNC_PASS_GENERATED=; verify_and_report'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[ OK ] VNC password: set from VNC_PASSWORD (not shown)')" -eq 1 ]
  [[ "$output" != *Abc123* ]] || false
}

@test "VR-3: a kept, non-empty ~/.vnc/passwd is reported unchanged" {
  mkdir -p "$HOME/.vnc"
  printf 'OLDPASS!' > "$HOME/.vnc/passwd"
  fn 'VNC_PASS_STATE=kept; VNC_PASS_GENERATED=; verify_and_report'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[ OK ] VNC password: unchanged')" -eq 1 ]
}

@test "VR-4: a kept but empty ~/.vnc/passwd is NG" {
  mkdir -p "$HOME/.vnc"
  : > "$HOME/.vnc/passwd"
  fn 'VNC_PASS_STATE=kept; VNC_PASS_GENERATED=; verify_and_report'
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[ NG ] VNC password: ~/.vnc/passwd was not created')" -eq 1 ]
  [[ "$output" == *Result* ]] || false
  [[ "$output" == *'Setup is NOT complete'* ]] || false
}

@test "VR-5: failed or unset state is NG" {
  fn 'VNC_PASS_STATE=failed; VNC_PASS_GENERATED=; verify_and_report'
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[ NG ] VNC password:')" -eq 1 ]
  fn 'unset VNC_PASS_STATE VNC_PASS_GENERATED; verify_and_report'
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[ NG ] VNC password:')" -eq 1 ]
}

@test "VR-6: the password line is shown even when VNC did not start (systemd)" {
  atst_test_stub_script "$B" systemctl exit1
  export ATST_TEST_SS_PORTS=22
  fn 'IS_SYSTEMD=1; VNC_PASS_STATE=generated; VNC_PASS_GENERATED=Zx9Qw2Lp; verify_and_report'
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[ NG ] VNC: vncserver@:1 is not running')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[ OK ] VNC password: Zx9Qw2Lp')" -eq 1 ]
}

@test "VR-7: from setup to report, the password appears once on stdout and nowhere else" {
  export ATST_TEST_SS_PORTS=5901
  fn 'IS_SYSTEMD=1; VNC_PASS_GIVEN=
    { setup_vncserver; verify_and_report; } > "$ATST_TEST_SANDBOX/out" 2> "$ATST_TEST_SANDBOX/err"
    echo "rc=$?"'
  [ "$output" = 'rc=0' ]
  local v
  v=$(cat "$ATST_TEST_SANDBOX/vncpasswd.stdin")
  [[ "$v" =~ ^[A-Za-z0-9]{8}$ ]] || false
  [ "$(grep -oF "$v" "$ATST_TEST_SANDBOX/out" | wc -l)" -eq 1 ]
  grep -qF "[ OK ] VNC password: $v" "$ATST_TEST_SANDBOX/out"
  [ "$(grep -cF "$v" "$ATST_TEST_SANDBOX/err")" -eq 0 ]
  [ -z "$(grep -rlF "$v" "$HOME")" ]
  [ -s "$ATST_TEST_SANDBOX/calls.log" ]
  [ "$(grep -cF "$v" "$ATST_TEST_SANDBOX/calls.log")" -eq 0 ]
}

@test "VR-8: a generated password is shown once by the EXIT trap when the run stops before the report" {
  run bash -c '
    on_exit_src=$(sed -n "/^function on_exit() {/,/^}/p" "$1")
    release_wine_hold() { :; }; ensure_sshd_alive() { :; }
    eval "$on_exit_src"
    VNC_PASS_STATE=generated; VNC_PASS_GENERATED=Zx9Qw2Lp
    on_exit 2>/dev/null
    VNC_PASS_REPORTED=1; on_exit 2>/dev/null
    VNC_PASS_STATE=env; VNC_PASS_REPORTED=; on_exit 2>/dev/null
  ' _ "$I"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -oF Zx9Qw2Lp | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF '[info] VNC password: Zx9Qw2Lp (generated in this run, which stopped early')" -eq 1 ]
}
