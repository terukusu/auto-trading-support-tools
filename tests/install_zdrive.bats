#!/usr/bin/env bats
# The Z: drive opt-in of install_required_for_mt.sh (#145), without running the installer:
# - zdrive_opt_in / remove_z_drive / prepare_mt_installer_dir come from sourcing it with
#   ATST_INSTALL_SOURCE_ONLY=1 (ZD-01..08).
# - the top level that takes ATST_INSTALL_NO_ZDRIVE runs from head.sh, a copy cut before TARGET_LOCALE=
#   with a probe at the end (ZD-09).
# - download_and_start_mt4_installer / verify_and_report are cut out with sed and run with mocks
#   defined as shell functions (wget, wine, sleep, pgrep), so no real wine / network is used (ZD-10, 11).
# The fake z: never points to /: it points to a directory in the sandbox (same -L / -e behaviour).

load test_helper

setup() {
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  I="$repo/install_required_for_mt.sh"
  D="$WINEPREFIX/dosdevices"
  mkdir -p "$D" "$WINEPREFIX/drive_c" "$ATST_TEST_SANDBOX/fakeroot"
  ln -s "$ATST_TEST_SANDBOX/fakeroot" "$D/z:"
  ln -s ../drive_c "$D/c:"
}

teardown() {
  atst_test_teardown_sandbox
}

# src <commands> [<value>]: runs <commands> after sourcing only the installer; <value> is "$2" there.
src() {
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1" && eval "$3"' _ "$I" "${2-}" "$1"
}

# fn <name>...: cuts the named functions of the installer into fn.sh (a failed cut must not pass).
fn_cut() {
  FN="$ATST_TEST_SANDBOX/fn.sh"
  : > "$FN"
  local f
  for f in "$@"; do
    sed -n "/^function $f/,/^}/p" "$I" >> "$FN"
  done
  [ "$(grep -c '^function ' "$FN")" -eq "$#" ]
}

# --- remove_z_drive ------------------------------------------------------------------------------

@test "ZD-01: remove_z_drive removes the z: link only, keeps c: and the link target, tells how to restore" {
  touch "$ATST_TEST_SANDBOX/fakeroot/keep"
  src 'remove_z_drive'
  [ "$status" -eq 0 ]
  [ ! -L "$D/z:" ]
  [ ! -e "$D/z:" ]
  [ -L "$D/c:" ]
  [ -f "$ATST_TEST_SANDBOX/fakeroot/keep" ]
  [[ "$output" == *"ln -s / "* ]] || false
}

@test "ZD-02: remove_z_drive twice: the second call is rc 0 and changes nothing (idempotent)" {
  src 'remove_z_drive >/dev/null && remove_z_drive && echo second-ok'
  [ "$status" -eq 0 ]
  [[ "$output" == *second-ok* ]] || false
  [ ! -L "$D/z:" ]
  [ -L "$D/c:" ]
  [ "$(ls -A "$D" | wc -l)" -eq 1 ]
}

@test "ZD-03: no z: -> rc 0 and nothing made; a dangling z: link is removed too" {
  rm -f "$D/z:"
  src 'remove_z_drive'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -L "$D/z:" ]
  [ ! -e "$D/z:" ]

  ln -s "$ATST_TEST_SANDBOX/nonexistent" "$D/z:"
  src 'remove_z_drive'
  [ "$status" -eq 0 ]
  [ ! -L "$D/z:" ]
}

@test "ZD-04: a z: that is a real directory is left as it is (rc 1, warning)" {
  rm -f "$D/z:"
  mkdir "$D/z:"
  touch "$D/z:/file"
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1" && remove_z_drive 2>"$2"' _ "$I" "$ATST_TEST_SANDBOX/err"
  [ "$status" -eq 1 ]
  grep -q '^\[warn\] .*not a symbolic link' "$ATST_TEST_SANDBOX/err"
  [ -d "$D/z:" ]
  [ -f "$D/z:/file" ]
}

@test "ZD-05: an empty or unset WINEPREFIX never reaches rm (rc non-zero, the link stays)" {
  src 'WINEPREFIX= remove_z_drive'
  [ "$status" -ne 0 ]
  [[ "$output" == *"WINEPREFIX is empty"* ]] || false
  src 'unset WINEPREFIX; remove_z_drive'
  [ "$status" -ne 0 ]
  [ -L "$D/z:" ]
  # The rm line is only "rm -f -- ${WINEPREFIX:?}/dosdevices/z:" and a [ -L check comes before it.
  [ "$(grep -c '^[^#]*rm -f -- "${WINEPREFIX:?}/dosdevices/z:"' "$I")" -eq 1 ]
  fn_cut remove_z_drive
  local l_check l_rm
  l_check=$(grep -n 'if \[ -L "\$z" \]' "$FN" | cut -d: -f1)
  l_rm=$(grep -n 'rm -f -- ' "$FN" | cut -d: -f1)
  [ -n "$l_check" ] && [ -n "$l_rm" ] && [ "$l_check" -lt "$l_rm" ]
}

# --- zdrive_opt_in -------------------------------------------------------------------------------

@test "ZD-06: zdrive_opt_in: only 1 enables; empty is silent; other values warn once without the value" {
  src 'zdrive_opt_in "$2"' 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  src 'zdrive_opt_in "$2"' ''
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  local v
  for v in 0 true yes ' 1' '1 ' 01 secretvalue; do
    src 'zdrive_opt_in "$2"' "$v"
    [ "$status" -eq 1 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == "[warn] ATST_INSTALL_NO_ZDRIVE must be 1"* ]] || false
    [[ "$output" != *secretvalue* ]] || false
  done
}

# --- prepare_mt_installer_dir --------------------------------------------------------------------

@test "ZD-07: prepare_mt_installer_dir prints drive_c/atst/installer, both levels 700, idempotent" {
  mkdir -m 755 "$WINEPREFIX/drive_c/atst"
  run bash -c 'umask 022; ATST_INSTALL_SOURCE_ONLY=1 . "$1" && prepare_mt_installer_dir && prepare_mt_installer_dir' _ "$I"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$WINEPREFIX/drive_c/atst/installer" ]
  [ "${lines[1]}" = "$WINEPREFIX/drive_c/atst/installer" ]
  [ "$(stat -c %a "$WINEPREFIX/drive_c/atst")" = 700 ]
  [ "$(stat -c %a "$WINEPREFIX/drive_c/atst/installer")" = 700 ]
}

@test "ZD-08: prepare_mt_installer_dir refuses symbolic links and a prefix without drive_c" {
  mkdir -p "$ATST_TEST_SANDBOX/elsewhere"
  ln -s "$ATST_TEST_SANDBOX/elsewhere" "$WINEPREFIX/drive_c/atst"
  src 'prepare_mt_installer_dir'
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a symbolic link"* ]] || false
  [ ! -e "$ATST_TEST_SANDBOX/elsewhere/installer" ]

  rm -f "$WINEPREFIX/drive_c/atst"
  mkdir -m 700 "$WINEPREFIX/drive_c/atst"
  ln -s "$ATST_TEST_SANDBOX/elsewhere" "$WINEPREFIX/drive_c/atst/installer"
  src 'prepare_mt_installer_dir'
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$ATST_TEST_SANDBOX/elsewhere")" ]

  rm -rf "$WINEPREFIX/drive_c"
  src 'prepare_mt_installer_dir'
  [ "$status" -eq 1 ]
  [ ! -e "$WINEPREFIX/drive_c" ]

  src 'WINEPREFIX= prepare_mt_installer_dir'
  [ "$status" -eq 1 ]
}

# --- top level -----------------------------------------------------------------------------------

@test "ZD-09: the top level sets NO_ZDRIVE=1 only for ATST_INSTALL_NO_ZDRIVE=1; the call is inside its if" {
  local head="$ATST_TEST_SANDBOX/head.sh"
  sed '/^TARGET_LOCALE=/,$d' "$I" > "$head"
  echo 'echo "NO_ZDRIVE=$NO_ZDRIVE"' >> "$head"
  [ "$(grep -cE '^[^#]*(trap |apt-get|sudo |/etc/os-release)' "$head")" -eq 0 ]

  run env ATST_INSTALL_NO_ZDRIVE=1 bash "$head"
  [ "$status" -eq 0 ]
  [ "$output" = "NO_ZDRIVE=1" ]
  run env -u ATST_INSTALL_NO_ZDRIVE bash "$head"
  [ "$output" = "NO_ZDRIVE=0" ]
  run env ATST_INSTALL_NO_ZDRIVE=true bash "$head"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn] ATST_INSTALL_NO_ZDRIVE must be 1"* ]] || false
  [[ "$output" == *"NO_ZDRIVE=0" ]] || false

  # remove_z_drive is called once, right after setup_wine and inside "if [ "$NO_ZDRIVE" = 1 ]".
  local calls l_call l_if l_fi l_wine
  calls=$(grep -n '^[^#]*remove_z_drive' "$I" | grep -v 'function remove_z_drive')
  [ "$(printf '%s\n' "$calls" | wc -l)" -eq 1 ]
  l_call=${calls%%:*}
  l_if=$(grep -n '^if \[ "\$NO_ZDRIVE" = 1 \]; then$' "$I" | cut -d: -f1)
  l_wine=$(grep -n '^setup_wine || die' "$I" | cut -d: -f1)
  [ -n "$l_if" ] && [ -n "$l_wine" ]
  l_fi=$(awk -v s="$l_if" 'NR > s && /^fi$/ { print NR; exit }' "$I")
  [ "$l_wine" -lt "$l_if" ] && [ "$l_if" -lt "$l_call" ] && [ "$l_call" -lt "$l_fi" ]
  # The old cache outside drive_c is gone.
  [ "$(grep -c '\.cache/wine' "$I")" -eq 0 ]
  [ "$(grep -c 'DIR_WINECACHE' "$I")" -eq 0 ]
}

# --- download_and_start_mt4_installer / verify_and_report ----------------------------------------

mocks() {
  MOCKS="$ATST_TEST_SANDBOX/mocks.sh"
  cat > "$MOCKS" <<'EOS'
MT_INSTALLER_URL='https://example.invalid/path/setup.exe'
WINE_PIN_VERSION='10.0.*'
IS_SYSTEMD=
VNC_PASS_STATE=env
wineprefix_arch() { echo "${ATST_TEST_ARCH:-win64}"; }
wineprefix_ok() { return 0; }
ensure_sshd_alive() { return 0; }
reboot_required_reason() { :; }
sleep() { :; }
pgrep() { return 0; }
wget() {
  local dir="" a
  while [ $# -gt 0 ]; do
    case $1 in -P) dir=$2; shift ;; esac
    a=$1; shift
  done
  echo "wget -P $dir" >> "$ATST_TEST_SANDBOX/calls.log"
  [ -n "${ATST_TEST_WGET_FAIL:-}" ] && return 4
  printf 'MZ' > "$dir/${a##*/}"
}
wine() {
  if [ "$1" = --version ]; then echo wine-10.0; return 0; fi
  echo "wine $*" >> "$ATST_TEST_SANDBOX/calls.log"
}
EOS
}

@test "ZD-10: the installer is saved in drive_c/atst/installer and started from there with wine start /unix" {
  mocks
  fn_cut download_and_start_mt4_installer
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1" && . "$2" && . "$3" && download_and_start_mt4_installer
    echo "status=$INSTALLER_STATUS"' _ "$I" "$MOCKS" "$FN"
  [ "$status" -eq 0 ]
  [[ "$output" == *status=running* ]] || false
  local d="$WINEPREFIX/drive_c/atst/installer"
  [ -f "$d/setup.exe" ]
  grep -qxF "wget -P $d" "$ATST_TEST_SANDBOX/calls.log"
  grep -qxF "wine start /unix $d/setup.exe" "$ATST_TEST_SANDBOX/calls.log"
  [ ! -e "$HOME/.cache/wine" ]

  # A symbolic link in the way: no download, no wine, status no-dir.
  rm -rf "$WINEPREFIX/drive_c/atst"
  mkdir -p "$ATST_TEST_SANDBOX/elsewhere"
  ln -s "$ATST_TEST_SANDBOX/elsewhere" "$WINEPREFIX/drive_c/atst"
  : > "$ATST_TEST_SANDBOX/calls.log"
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1" && . "$2" && . "$3"; download_and_start_mt4_installer
    echo "rc=$? status=$INSTALLER_STATUS"' _ "$I" "$MOCKS" "$FN"
  [[ "$output" == *"rc=1 status=no-dir"* ]] || false
  [ ! -s "$ATST_TEST_SANDBOX/calls.log" ]
  [ -z "$(ls -A "$ATST_TEST_SANDBOX/elsewhere")" ]
}

@test "ZD-11: verify_and_report: Z: line only with NO_ZDRIVE=1 (OK when gone, NG when present); no-dir is NG" {
  mocks
  fn_cut verify_and_report
  local run_v='ATST_INSTALL_SOURCE_ONLY=1 . "$1" && . "$2" && . "$3"; INSTALLER_STATUS=${4:-running}; NO_ZDRIVE=$5; verify_and_report'

  run bash -c "$run_v" _ "$I" "$MOCKS" "$FN" running 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ NG ] wine Z: drive: "*"dosdevices/z: is still present"* ]] || false

  rm -f "$D/z:"
  run bash -c "$run_v" _ "$I" "$MOCKS" "$FN" running 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ OK ] wine Z: drive: removed"* ]] || false

  ln -s "$ATST_TEST_SANDBOX/nonexistent" "$D/z:"
  run bash -c "$run_v" _ "$I" "$MOCKS" "$FN" running 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ NG ] wine Z: drive:"* ]] || false

  run bash -c "$run_v" _ "$I" "$MOCKS" "$FN" running 0
  [ "$status" -eq 0 ]
  [[ "$output" != *"Z: drive"* ]] || false
  run bash -c "$run_v" _ "$I" "$MOCKS" "$FN" running ''
  [ "$status" -eq 0 ]
  [[ "$output" != *"Z: drive"* ]] || false

  run bash -c "$run_v" _ "$I" "$MOCKS" "$FN" no-dir 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ NG ] MetaTrader installer: not started (cannot prepare "*"drive_c/atst/installer"* ]] || false
}
