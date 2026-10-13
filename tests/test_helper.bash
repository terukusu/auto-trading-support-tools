#!/bin/bash
# Shared fixtures for tests/*.bats (read with "load test_helper").
# Tests must call atst_test_setup_sandbox before reading common.sh so that the real ~/.atst,
# ~/.wine, LINE and Wine are never touched.

# Creates a sandbox and points HOME / WINEPREFIX / PATH / ATST_TEST_CURL_LOG into it.
# WINEPREFIX itself is not created here (atst_test_make_mt creates it).
atst_test_setup_sandbox() {
  ATST_TEST_SANDBOX=$(mktemp -d "${BATS_TMPDIR:-/tmp}/atst-test.XXXXXX") || return 1
  HOME="$ATST_TEST_SANDBOX/home"
  mkdir -p "$HOME" || return 1
  WINEPREFIX="$ATST_TEST_SANDBOX/prefix"
  unset WINEARCH
  PATH="${BATS_TEST_DIRNAME:?}/stubs:$PATH"
  ATST_TEST_CURL_LOG="$ATST_TEST_SANDBOX/curl.log"
  export ATST_TEST_SANDBOX HOME WINEPREFIX PATH ATST_TEST_CURL_LOG
}

# Removes the sandbox. Refuses anything that is not a sandbox made by atst_test_setup_sandbox.
atst_test_teardown_sandbox() {
  [ -n "${ATST_TEST_SANDBOX:-}" ] || return 0
  case "$ATST_TEST_SANDBOX" in
    */atst-test.*) ;;
    *) return 1 ;;
  esac
  rm -rf "${ATST_TEST_SANDBOX:?}"
}

# atst_test_make_mt <name> <MT4|MT5> [<appdata-hash>]
# Creates a fake MetaTrader install under $WINEPREFIX/drive_c/Program Files/<name>. With a hash,
# also creates its AppData data folder with origin.txt (UTF-16LE with BOM), MQL4|MQL5/Files and logs.
atst_test_make_mt() {
  local name="$1" type="$2" hash="${3:-}"
  local mql home data

  [ -n "$name" ] || return 1
  case "$type" in
    MT4|MT5) ;;
    *) return 1 ;;
  esac
  [ -n "${WINEPREFIX:-}" ] || return 1
  mql="${type/MT/MQL}"

  home="$WINEPREFIX/drive_c/Program Files/$name"
  mkdir -p "$home/$mql" || return 1
  : > "$home/terminal.exe" || return 1

  if [ ! -e "$WINEPREFIX/system.reg" ]; then
    printf '#arch=win64\n' > "$WINEPREFIX/system.reg" || return 1
  fi

  if [ -n "$hash" ]; then
    data="$WINEPREFIX/drive_c/users/tester/AppData/Roaming/MetaQuotes/Terminal/$hash"
    mkdir -p "$data/$mql/Files" "$data/logs" || return 1
    { printf '\xff\xfe'; printf '%s' "C:\\Program Files\\$name" | iconv -f UTF-8 -t UTF-16LE; } \
      > "$data/origin.txt" || return 1
  fi
}

# Reads common.sh, only when HOME points into the sandbox.
atst_test_source_common() {
  [ -n "${ATST_TEST_SANDBOX:-}" ] && [ "$HOME" = "$ATST_TEST_SANDBOX/home" ] || return 1
  # shellcheck source=/dev/null
  . "${BATS_TEST_DIRNAME:?}/../common.sh"
}
