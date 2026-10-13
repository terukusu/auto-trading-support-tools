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

# atst_test_make_monitoring_csv <name> <secs_ago> <bid> <spread> <pip> [<ping>]
# Appends one 8-field line "<now-secs_ago>,0,<bid>,<bid>,<spread>,<ping>,<pip>,USDJPY" to
# MQL4/Files/terminal_monitoring.csv of the MT made by atst_test_make_mt (without a hash).
# <ping> is in microseconds (the 6th field read by check_ping.sh); the default is 12.
atst_test_make_monitoring_csv() {
  local name="$1" secs_ago="$2" bid="$3" spread="$4" pip="$5" ping="${6:-12}"
  local dir

  [ -n "${ATST_TEST_SANDBOX:-}" ] && [ "$HOME" = "$ATST_TEST_SANDBOX/home" ] || return 1
  { [ "$#" -eq 5 ] || [ "$#" -eq 6 ]; } && [ -n "$name" ] || return 1
  [ -n "${WINEPREFIX:-}" ] || return 1

  dir="$WINEPREFIX/drive_c/Program Files/$name/MQL4/Files"
  mkdir -p "$dir" || return 1
  printf '%s,%s,%s,%s,%s,%s,%s,USDJPY\n' "$(( $(date +%s) - secs_ago ))" 0 "$bid" "$bid" "$spread" "$ping" "$pip" \
    >> "$dir/terminal_monitoring.csv"
}

# atst_test_push_count
# Prints how many LINE pushes the curl stub recorded in $ATST_TEST_CURL_LOG (0 when there is no log).
atst_test_push_count() {
  if [ -e "${ATST_TEST_CURL_LOG:?}" ]; then
    grep -c 'api.line.me/v2/bot/message/push' "$ATST_TEST_CURL_LOG"
  else
    echo 0
  fi
}

# atst_test_make_order_status <name> <line>...
# Appends each <line> to MQL4/Files/order_status of the MT made by atst_test_make_mt (without a hash,
# the same folder as atst_test_make_monitoring_csv).
atst_test_make_order_status() {
  local name="$1"
  local dir

  [ -n "${ATST_TEST_SANDBOX:-}" ] && [ "$HOME" = "$ATST_TEST_SANDBOX/home" ] || return 1
  [ "$#" -ge 2 ] && [ -n "$name" ] || return 1
  [ -n "${WINEPREFIX:-}" ] || return 1
  shift

  dir="$WINEPREFIX/drive_c/Program Files/$name/MQL4/Files"
  mkdir -p "$dir" || return 1
  printf '%s\n' "$@" >> "$dir/order_status"
}

# atst_test_fake_mt_process <name>
# Starts "sleep 30" shown in the process table as "C:\Program Files\<name>\terminal.exe" (what
# atst_find_pid looks for) and prints its pid. Call it as
#   ATST_TEST_FAKE_PID=$(atst_test_fake_mt_process ATSTTEST_MT4)
# and kill that pid in teardown. Use a name no real MetaTrader can start with.
atst_test_fake_mt_process() {
  local name="$1"

  [ -n "${ATST_TEST_SANDBOX:-}" ] && [ "$HOME" = "$ATST_TEST_SANDBOX/home" ] || return 1
  [ "$#" -eq 1 ] && [ -n "$name" ] || return 1

  ( exec -a "C:\\Program Files\\$name\\terminal.exe" sleep 30 ) >/dev/null 2>&1 </dev/null 3>&- &
  echo "$!"
}

# atst_test_set_config <KEY> <value>
# Appends KEY=<value> to the sandbox ~/.atst/config (copied from templates/config first), so it wins
# over the template value. common.sh sources the config on every run, so environment variables cannot
# override it. KEY must be a shell variable name; the value is quoted with %q.
atst_test_set_config() {
  local key="$1" value="$2"
  local conf

  [ -n "${ATST_TEST_SANDBOX:-}" ] && [ "$HOME" = "$ATST_TEST_SANDBOX/home" ] || return 1
  [ "$#" -eq 2 ] || return 1
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1

  conf="$HOME/.atst/config"
  mkdir -p "$HOME/.atst" || return 1
  if [ ! -e "$conf" ]; then
    cp "${BATS_TEST_DIRNAME:?}/../templates/config" "$conf" || return 1
  fi
  printf '%s=%q\n' "$key" "$value" >> "$conf"
}
