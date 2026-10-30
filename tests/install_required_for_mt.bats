#!/usr/bin/env bats
# The WineHQ key fingerprint check and the MT installer sha256 line of install_required_for_mt.sh
# (#152), without running the installer:
# - static checks of the constant and the strings (IR-01..03).
# - keyring_primary_fpr comes from sourcing the script with ATST_INSTALL_SOURCE_ONLY=1 and runs the real
#   gpg on keys generated in the sandbox (IR-04..09). Skipped when gpg is not installed.
# - install_packages_misc_and_needed_by_mt4 / download_and_start_mt4_installer are cut out with sed and
#   run with mocks defined as shell functions (sudo, wget, grep, apt steps, wine), with the keyring and
#   list paths moved into the sandbox, so no real apt / sudo / network / wine is used (IR-10..12).
# The real behaviour on a fresh VPS (apt, root, wine) is checked by hand (Issue #152, Phase 5.5).

load test_helper

setup() {
  atst_test_setup_sandbox
  S="$ATST_TEST_SANDBOX"
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  I="$repo/install_required_for_mt.sh"
  # keyring_primary_fpr makes its throwaway GnuPG home with mktemp; keep it in the sandbox (IR-09).
  export TMPDIR="$S/tmp"
  mkdir -p "$TMPDIR"
  G="$S/gnupg"
  mkdir -m 700 "$G"
}

teardown() {
  if command -v gpgconf >/dev/null 2>&1; then
    gpgconf --homedir "$G" --kill gpg-agent >/dev/null 2>&1 || true
  fi
  atst_test_teardown_sandbox
}

need_gpg() {
  command -v gpg >/dev/null 2>&1 || skip "gpg not installed"
}

# gen_key <uid>: a throwaway signing key (no passphrase) in the sandbox GnuPG home.
gen_key() {
  gpg --batch --homedir "$G" --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "$1" ed25519 sign never >/dev/null 2>&1
}

# fpr_of <uid>: the fingerprint of the primary key of <uid>.
fpr_of() {
  gpg --batch --homedir "$G" --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'
}

# export_key <file> <uid>...: binary export (the same format as a dearmored keyring).
export_key() {
  local f=$1; shift
  gpg --batch --homedir "$G" --export "$@" > "$f"
}

# src <commands> [<value>]: runs <commands> after sourcing only the installer; <value> is "$2" there.
src() {
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1" && eval "$3"' _ "$I" "${2-}" "$1"
}

# fn_cut <name>...: cuts the named functions of the installer into fn.sh (a failed cut must not pass).
fn_cut() {
  FN="$S/fn.sh"
  : > "$FN"
  local f
  for f in "$@"; do
    sed -n "/^function $f/,/^}/p" "$I" >> "$FN"
  done
  [ "$(grep -c '^function ' "$FN")" -eq "$#" ]
}

# --- static ---------------------------------------------------------------------------------------

@test "IR-01: WINE_KEY_FINGERPRINT is defined once as a plain 40-hex constant" {
  [ "$(grep -cE "^WINE_KEY_FINGERPRINT='?[0-9A-Fa-f]{40}'?$" "$I")" -eq 1 ]
}

@test "IR-02: WINE_KEY_FINGERPRINT is used by the check and never taken from a variable" {
  [ "$(grep -c 'WINE_KEY_FINGERPRINT' "$I")" -ge 2 ]
  [ "$(grep -cE 'WINE_KEY_FINGERPRINT=.*\$\{?[A-Z_]+' "$I")" -eq 0 ]
}

@test "IR-03: the MT installer sha256 is computed with sha256sum and shown on one line" {
  [ "$(grep -c 'sha256sum' "$I")" -ge 1 ]
  [ "$(grep -c 'MetaTrader installer sha256:' "$I")" -eq 1 ]
}

# --- keyring_primary_fpr --------------------------------------------------------------------------

@test "IR-04: keyring_primary_fpr is available with ATST_INSTALL_SOURCE_ONLY=1" {
  src 'declare -F keyring_primary_fpr'
  [ "$status" -eq 0 ]
}

@test "IR-05: one primary key -> its fingerprint (40 upper-case hex) and rc 0" {
  need_gpg
  gen_key 'IR One <one@example.invalid>'
  export_key "$S/one.gpg" 'one@example.invalid'
  src 'keyring_primary_fpr "$2"' "$S/one.gpg"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" =~ ^[0-9A-F]{40}$ ]] || false
  [ "$output" = "$(fpr_of 'one@example.invalid')" ]
}

@test "IR-06: two primary keys -> nothing and rc 1" {
  need_gpg
  gen_key 'IR One <one@example.invalid>'
  gen_key 'IR Two <two@example.invalid>'
  export_key "$S/two.gpg" 'one@example.invalid' 'two@example.invalid'
  src 'keyring_primary_fpr "$2"' "$S/two.gpg"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "IR-06b: the genuine key plus another key's secret key -> nothing and rc 1" {
  need_gpg
  gen_key 'IR One <one@example.invalid>'
  gen_key 'IR Two <two@example.invalid>'
  export_key "$S/mixed.gpg" 'one@example.invalid'
  gpg --batch --homedir "$G" --pinentry-mode loopback --passphrase '' \
    --export-secret-keys 'two@example.invalid' >> "$S/mixed.gpg"
  src 'keyring_primary_fpr "$2"' "$S/mixed.gpg"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "IR-07: the same key twice -> nothing and rc 1" {
  need_gpg
  gen_key 'IR One <one@example.invalid>'
  export_key "$S/one.gpg" 'one@example.invalid'
  cat "$S/one.gpg" "$S/one.gpg" > "$S/dup.gpg"
  src 'keyring_primary_fpr "$2"' "$S/dup.gpg"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "IR-08: empty file / missing file / not a key -> nothing and rc 1" {
  need_gpg
  : > "$S/empty.gpg"
  printf 'not a key\n' > "$S/junk.gpg"
  local f
  for f in "$S/empty.gpg" "$S/missing.gpg" "$S/junk.gpg"; do
    src 'keyring_primary_fpr "$2"' "$f"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
}

@test "IR-09: keyring_primary_fpr neither creates ~/.gnupg nor leaves its GnuPG home behind" {
  need_gpg
  gen_key 'IR One <one@example.invalid>'
  export_key "$S/one.gpg" 'one@example.invalid'
  src 'keyring_primary_fpr "$2"; keyring_primary_fpr /nonexistent' "$S/one.gpg"
  [ ! -e "$HOME/.gnupg" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

# --- install_packages_misc_and_needed_by_mt4 / download_and_start_mt4_installer with mocks ----------

# Mocks for the WineHQ key block: keyring / list paths in the sandbox, sudo runs the command itself
# (apt-get, dpkg and install do nothing), wget prints the key file $ATST_TEST_KEY, the "already
# configured" grep says no, and the FAudio block is skipped (its list exists).
key_mocks() {
  MOCKS="$S/mocks.sh"
  mkdir -p "$S/apt/keyrings" "$S/apt/sources.list.d"
  : > "$S/apt/sources.list.d/faudio.list"
  cat > "$MOCKS" <<'EOS'
APT_OPT=-y
APT_KEYRINGS_DIR="$ATST_TEST_SANDBOX/apt/keyrings"
WINE_KEY_URL=https://example.invalid/winehq.key
WINE_KEYRING="$APT_KEYRINGS_DIR/winehq-archive.gpg"
WINE_LIST="$ATST_TEST_SANDBOX/apt/sources.list.d/winehq.list"
FAUDIO_LIST="$ATST_TEST_SANDBOX/apt/sources.list.d/faudio.list"
WINE_REPOS="deb [signed-by=$WINE_KEYRING arch=amd64,i386] https://example.invalid/ noble main"
sudo() {
  [ "$1" = -E ] && shift
  echo "sudo $*" >> "$ATST_TEST_SANDBOX/calls.log"
  case $1 in apt-get|dpkg|install) return 0 ;; esac
  "$@"
}
wget() { cat "$ATST_TEST_KEY"; }
grep() {
  case $* in *'winehq|wine-builds'*) return 1 ;; esac
  command grep "$@"
}
ensure_time_sync() { :; }
install_wine_packages() { echo "install_wine_packages" >> "$ATST_TEST_SANDBOX/calls.log"; }
ensure_sshd_alive() { :; }
EOS
}

# run_key <expected fingerprint>: runs install_packages_misc_and_needed_by_mt4 with the mocks.
run_key() {
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1" && . "$2" && . "$3"; WINE_KEY_FINGERPRINT=$4
    install_packages_misc_and_needed_by_mt4; echo "rc=$?"' _ "$I" "$MOCKS" "$FN" "$1"
}

@test "IR-10: matching key (any case) -> keyring kept, list written with signed-by, rc 0" {
  need_gpg
  gen_key 'IR One <one@example.invalid>'
  gpg --batch --homedir "$G" --armor --export 'one@example.invalid' > "$S/one.asc"
  export ATST_TEST_KEY="$S/one.asc"
  key_mocks
  fn_cut install_packages_misc_and_needed_by_mt4
  run_key "$(fpr_of 'one@example.invalid' | tr 'A-F' 'a-f')"
  [[ "$output" == *rc=0* ]] || false
  [[ "$output" != *"[error]"* ]] || false
  [ -s "$S/apt/keyrings/winehq-archive.gpg" ]
  command grep -qF "signed-by=$S/apt/keyrings/winehq-archive.gpg" "$S/apt/sources.list.d/winehq.list"
  command grep -qx install_wine_packages "$S/calls.log"
}

@test "IR-11: wrong fingerprint or two primary keys -> [error], keyring removed, no list, rc 1" {
  need_gpg
  gen_key 'IR One <one@example.invalid>'
  gen_key 'IR Two <two@example.invalid>'
  gpg --batch --homedir "$G" --armor --export 'one@example.invalid' > "$S/one.asc"
  gpg --batch --homedir "$G" --armor --export 'one@example.invalid' 'two@example.invalid' > "$S/two.asc"
  key_mocks
  fn_cut install_packages_misc_and_needed_by_mt4
  local one; one=$(fpr_of 'one@example.invalid')

  # The real key of IR One, but another fingerprint expected.
  export ATST_TEST_KEY="$S/one.asc"
  run_key "$(fpr_of 'two@example.invalid')"
  [[ "$output" == *rc=1* ]] || false
  [[ "$output" == *"[error] WineHQ key fingerprint mismatch"*"got $one"* ]] || false
  [ ! -e "$S/apt/keyrings/winehq-archive.gpg" ]
  [ ! -e "$S/apt/sources.list.d/winehq.list" ]
  [ "$(command grep -c install_wine_packages "$S/calls.log")" -eq 0 ]

  # The expected key plus another one in the same file.
  export ATST_TEST_KEY="$S/two.asc"
  run_key "$one"
  [[ "$output" == *rc=1* ]] || false
  [[ "$output" == *"[error] WineHQ key fingerprint mismatch"*"got none (not exactly one primary key"* ]] || false
  [ ! -e "$S/apt/keyrings/winehq-archive.gpg" ]
  [ ! -e "$S/apt/sources.list.d/winehq.list" ]
  [ "$(command grep -c install_wine_packages "$S/calls.log")" -eq 0 ]
}

@test "IR-12: the MT installer sha256 is shown with the file name before wine starts it" {
  MOCKS="$S/mocks.sh"
  cat > "$MOCKS" <<'EOS'
MT_INSTALLER_URL='https://example.invalid/path/setup.exe'
wineprefix_arch() { echo win64; }
sleep() { :; }
pgrep() { return 0; }
wget() {
  local dir="" a
  while [ $# -gt 0 ]; do
    case $1 in -P) dir=$2; shift ;; esac
    a=$1; shift
  done
  printf 'MZ' > "$dir/${a##*/}"
}
wine() { echo "wine $*"; }
EOS
  mkdir -p "$WINEPREFIX/drive_c"
  fn_cut download_and_start_mt4_installer
  run bash -c 'ATST_INSTALL_SOURCE_ONLY=1 . "$1" && . "$2" && . "$3" && download_and_start_mt4_installer' _ "$I" "$MOCKS" "$FN"
  [ "$status" -eq 0 ]
  local want; want=$(printf 'MZ' | sha256sum | cut -d' ' -f1)
  [ "$(printf '%s\n' "$output" | command grep -cxF "MetaTrader installer sha256: $want  setup.exe")" -eq 1 ]
  # Shown before the installer is started.
  [ "$(printf '%s\n' "$output" | command grep -n 'sha256:' | cut -d: -f1)" -lt "$(printf '%s\n' "$output" | command grep -n '^wine start' | cut -d: -f1)" ]
}
