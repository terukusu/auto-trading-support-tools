# shellcheck shell=bash
# Sourced by common.sh only (ATST_HOME is set there). Do not source this file on its own.
ATST_TEMPLATES_DIR="$ATST_HOME/templates"
ATST_CONFIG_DIR="$HOME/.atst"

if [ ! -e "$ATST_CONFIG_DIR" ];then
  mkdir -p "$ATST_CONFIG_DIR"
fi

if [ ! -e "$ATST_CONFIG_DIR/config" ]; then
  install -m 644 -D "$ATST_TEMPLATES_DIR/config" "$ATST_CONFIG_DIR/config"
fi

ATST_CONFIG_FILE="$ATST_CONFIG_DIR/config"
# These settings come from ~/.atst/config only. A value left in the environment (a manual run, a test)
# would hide that an existing user's config lacks them (check_all.sh reports unset ATST_TARGETS).
unset ATST_TARGETS ATST_CHECK_TIMEOUT ATST_ORDER_CHECK_INTERVAL ATST_ALERT_REMIND_MINUTES
# ATST_NOTIFY_SPOOL (the spool of one check_all.sh run, see atst_spool_begin) comes from the
# environment only: a value written in ~/.atst/config would make every check keep its notices in a
# spool nobody sends (P1). Keep the inherited value across the source and drop the config's.
_atst_spool_env=${ATST_NOTIFY_SPOOL-}
# A syntax error (an unclosed quote or parenthesis) stops reading the config at that line; a line that
# fails when run (`X= 180`, a failing $(...)) is skipped and the lines after it are still read. Warn on
# either with one line; bash's own message (file and line) stays on stderr. The caller goes on as before.
_atst_cfg_failed=0
if [ -z "$(trap -p ERR)" ]; then
  # Caught by an ERR trap of our own. The source must not sit in a condition (if/!/&&/||): bash runs
  # no ERR trap there. A caller's set -e would stop the caller at the failing line, so drop it for the
  # source and put it back after.
  case $- in *e*) _atst_cfg_errexit=1 ;; *) _atst_cfg_errexit=0 ;; esac
  set +e
  trap '_atst_cfg_failed=1' ERR
  # shellcheck source=/dev/null  # ~/.atst/config lives outside the repository
  . "$ATST_CONFIG_FILE"
  [ "$?" -eq 0 ] || _atst_cfg_failed=1
  trap - ERR
  if [ "$_atst_cfg_errexit" = 1 ]; then
    set -e
  fi
  unset _atst_cfg_errexit
else
  # The caller has an ERR trap of its own (bats does): leave it alone and judge by the return value
  # only, as before. A line that fails when run is not caught on this path.
  # shellcheck source=/dev/null  # ~/.atst/config lives outside the repository
  . "$ATST_CONFIG_FILE" || _atst_cfg_failed=1
fi
if [ "$_atst_cfg_failed" = 1 ]; then
  echo "[warn] ~/.atst/config may not have been read completely (syntax error or a failing line)" 1>&2
fi
unset _atst_cfg_failed
if [ -n "$_atst_spool_env" ]; then
  export ATST_NOTIFY_SPOOL="$_atst_spool_env" 2>/dev/null
else
  unset ATST_NOTIFY_SPOOL 2>/dev/null
fi
unset _atst_spool_env

# atst_load_heartbeat_url
# The heartbeat URL (heartbeat.sh) comes from ~/.atst/.heartbeat_url (written by setup_heartbeat.sh)
# when its first line, without spaces / CR / LF, is not empty; otherwise from ATST_HEARTBEAT_URL of
# ~/.atst/config, as before. Sets ATST_HEARTBEAT_URL and ATST_HEARTBEAT_URL_FROM (file / config / empty)
# without exporting them. Read here, after the config, so an existing config needs no new line. Prints
# nothing (not even a read error; the URL is a secret, P5) and always returns 0.
function atst_load_heartbeat_url() {
  local u=''

  if [ -n "$ATST_CONFIG_DIR" ]; then
    # The braces also silence bash's own message for an unreadable file or a directory. "|| :" keeps
    # a caller's set -e (and bats) going when there is no file or no final newline.
    { IFS= read -r u < "$ATST_CONFIG_DIR/.heartbeat_url"; } 2>/dev/null || :
    u=${u//[[:space:]]/}
  fi
  # shellcheck disable=SC2034  # ATST_HEARTBEAT_URL_FROM is read by doctor.sh
  if [ -n "$u" ]; then
    ATST_HEARTBEAT_URL=$u
    ATST_HEARTBEAT_URL_FROM='file'
  elif [ -n "${ATST_HEARTBEAT_URL:-}" ]; then
    ATST_HEARTBEAT_URL_FROM='config'
  else
    ATST_HEARTBEAT_URL_FROM=
  fi
  return 0
}
atst_load_heartbeat_url

# MT4/5 need neither Wine-Mono (.NET) nor Wine-Gecko (embedded IE). Keep both disabled for every
# wine call made from cron (mtctl start, ...) so Wine never opens a download dialog unattended
# (P10). cron does not read ~/.bash_profile, so this must live here.
# A value already set in the environment or ~/.atst/config (even empty, to opt out) wins.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES-mscoree=;mshtml=}"
