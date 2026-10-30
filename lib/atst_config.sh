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

# atst_config_parse <file>
# Reads <file> line by line with bash builtins only (no outside command; nothing in it is run). When
# every line is in the KEY=VALUE form of docs/config.md (a blank or # line, KEY=value, KEY="value",
# KEY='value', ATST_TARGETS=('a' "b") on one line), assigns the values in file order (the later line
# wins), sets ATST_CONFIG_FORMAT=strict and an empty ATST_CONFIG_FORMAT_LINE, and returns 0. Otherwise
# (one line out of the form, or a file it cannot read) assigns nothing, sets ATST_CONFIG_FORMAT=legacy
# and ATST_CONFIG_FORMAT_LINE to the first such line (0 when unreadable), and returns 1. Neither is
# exported. Prints nothing: values may be secrets (P5).
# shellcheck disable=SC2034  # ATST_TARGETS / ATST_CONFIG_FORMAT* are read by the callers and doctor.sh
function atst_config_parse() {
  local file=$1 line key val inner m n=0 i ok has_tgt=0
  local -a keys=() vals=() tgt=() elems=()
  # Only names matching re_key are given to printf -v ("a[$(x)]" would run x). [ \t] is written with
  # $'...' because the regex library does not read \t; [[:space:]] would also take a CR.
  local re_key='^(ATST_[A-Z0-9_]+|WINEPREFIX|WINEARCH|WINEDEBUG|WINEDLLOVERRIDES|DISPLAY)$'
  local re_assign='^([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  local re_blank=$'^[ \t]*$' re_comment=$'^[ \t]*#'
  local re_c=$'^([A-Za-z0-9_./:@%+,=-]*)[ \t]*$'
  local re_d=$'^"([^"\\\\$`]*)"[ \t]*$'
  local re_e=$'^\'([^\']*)\'[ \t]*$'
  local re_arr=$'^\\((.*)\\)[ \t]*$'
  local re_elem=$'^[ \t]*("[^"\\\\$`]*"|\'[^\']*\')(.*)$'

  ATST_CONFIG_FORMAT=legacy
  ATST_CONFIG_FORMAT_LINE=0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    ok=0
    if [[ $line == *$'\r'* ]]; then
      ok=0
    elif [[ $line =~ $re_blank || $line =~ $re_comment ]]; then
      ok=1
    elif [[ $line =~ $re_assign ]]; then
      key=${BASH_REMATCH[1]}
      val=${BASH_REMATCH[2]}
      case $key in
        ATST_HOME|ATST_TEMPLATES_DIR|ATST_CONFIG_DIR|ATST_CONFIG_FILE|ATST_NOTIFY_SPOOL|ATST_CONFIG_FORMAT|ATST_CONFIG_FORMAT_LINE) ;;
        ATST_TARGETS)
          # One line, each element quoted, elements apart by blanks. A scalar is not taken.
          if [[ $val =~ $re_arr ]]; then
            inner=${BASH_REMATCH[1]}
            elems=()
            ok=1
            while ! [[ $inner =~ $re_blank ]]; do
              if ! [[ $inner =~ $re_elem ]]; then
                ok=0
                break
              fi
              m=${BASH_REMATCH[1]}
              inner=${BASH_REMATCH[2]}
              elems+=("${m:1:${#m}-2}")
              case $inner in
                [$' \t']*|'') ;;
                *) ok=0; break ;;
              esac
            done
            if [ "$ok" = 1 ]; then
              tgt=("${elems[@]}")
              has_tgt=1
            fi
          fi
          ;;
        *)
          if [[ $key =~ $re_key ]]; then
            if [[ $val =~ $re_d || $val =~ $re_e || $val =~ $re_c ]]; then
              keys+=("$key")
              vals+=("${BASH_REMATCH[1]}")
              ok=1
            fi
          fi
          ;;
      esac
    fi
    if [ "$ok" != 1 ]; then
      ATST_CONFIG_FORMAT_LINE=$n
      return 1
    fi
  done 2>/dev/null < "$file"

  for i in "${!keys[@]}"; do
    printf -v "${keys[i]}" '%s' "${vals[i]}"
  done
  if [ "$has_tgt" = 1 ]; then
    ATST_TARGETS=("${tgt[@]}")
  fi
  ATST_CONFIG_FORMAT=strict
  ATST_CONFIG_FORMAT_LINE=
  return 0
}

# atst_config_defaults
# The values templates/config works out with bash code, for a KEY=VALUE config (which cannot hold that
# code): each is set only when empty, by the same rule as the template, and WINEARCH / WINEPREFIX /
# WINEDEBUG / DISPLAY are exported as the template does. Not called for an old-form config with the
# template's code (that code has done it). Prints nothing, always returns 0.
function atst_config_defaults() {
  local f

  if [ -z "${ATST_ALERT_STATUS_FILE-}" ]; then
    ATST_ALERT_STATUS_FILE="$ATST_CONFIG_DIR/alert_status"
  fi
  if [ -z "${ATST_LINE_TOKEN-}" ]; then
    f="$ATST_CONFIG_DIR/.line_token"
    ATST_LINE_TOKEN=$(if [ -e "$f" ]; then cat "$f" 2>/dev/null; fi || :)
  fi
  if [ -z "${ATST_LINE_ID-}" ]; then
    f="$ATST_CONFIG_DIR/.line_id"
    ATST_LINE_ID=$(if [ -e "$f" ]; then cat "$f" 2>/dev/null; fi || :)
  fi
  if [ -z "${WINEPREFIX-}" ]; then
    WINEPREFIX=$HOME/.wine
  fi
  if [ -z "${WINEARCH-}" ]; then
    if [ -d "$WINEPREFIX" ]; then
      # Empty when system.reg has no #arch line, as with the template.
      WINEARCH=$(grep -m 1 '#arch' "$WINEPREFIX/system.reg" 2>/dev/null | cut -d '=' -f2 || :)
    else
      WINEARCH=win64
    fi
  fi
  if [ -z "${WINEDEBUG-}" ]; then
    WINEDEBUG=-all,err+all
  fi
  if [ -z "${DISPLAY-}" ]; then
    DISPLAY=:1
  fi
  export WINEARCH WINEPREFIX WINEDEBUG DISPLAY
  return 0
}

# These settings come from ~/.atst/config only. A value left in the environment (a manual run, a test)
# would hide that an existing user's config lacks them (check_all.sh reports unset ATST_TARGETS).
unset ATST_TARGETS ATST_CHECK_TIMEOUT ATST_ORDER_CHECK_INTERVAL ATST_ALERT_REMIND_MINUTES
# ATST_NOTIFY_SPOOL (the spool of one check_all.sh run, see atst_spool_begin) comes from the
# environment only: a value written in ~/.atst/config would make every check keep its notices in a
# spool nobody sends (P1). Keep the inherited value across the source and drop the config's.
_atst_spool_env=${ATST_NOTIFY_SPOOL-}
# A config in the KEY=VALUE form (every line taken by atst_config_parse) is assigned without
# being run. Any other config (the template as it is, too) is read as bash below, as before.
atst_config_parse "$ATST_CONFIG_FILE" || :
if [ "$ATST_CONFIG_FORMAT" = legacy ]; then
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
fi
if [ -n "$_atst_spool_env" ]; then
  export ATST_NOTIFY_SPOOL="$_atst_spool_env" 2>/dev/null
else
  unset ATST_NOTIFY_SPOOL 2>/dev/null
fi
unset _atst_spool_env
# The template fills these with code; a KEY=VALUE config cannot, so fill them here. Also for a
# KEY=VALUE config with a mistyped line (read as bash above, it has no such code), so a typo still
# reaches LINE. An old-form config with the template's code (it sets ATST_CONFIG_DIR) keeps what that
# code gave, even empty when it broke before it (#110).
if [ "$ATST_CONFIG_FORMAT" = strict ] || ! grep -q '^ATST_CONFIG_DIR=' "$ATST_CONFIG_FILE" 2>/dev/null; then
  atst_config_defaults
fi

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
