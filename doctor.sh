#!/bin/bash
# doctor.sh: read-only self check of atst (#132).
# Prints one line per item, "<OK|NG|--> <label> <value>", and extra information on lines indented
# with two spaces. -- means not set / nothing to check / shown only. Exits 1 when any item is NG.
# Changes nothing: no file is written, crontab is only listed, MetaTrader / Wine are neither started
# nor stopped, nothing is sent to LINE and nothing goes out to the network. Secrets are shown as their
# last 4 characters at most, the LINE ID not at all, and the home directory as ~, so the output can be
# pasted into an Issue.

# Checked before common.sh is read, so a wrong call does not even create ~/.atst/config.
if [ "$#" -gt 0 ]; then
  echo "Usage: $(basename "$0")" 1>&2
  echo "  read-only self check of atst. takes no arguments." 1>&2
  exit 1
fi

# WINEPREFIX of the calling shell, before ~/.atst/config (read by common.sh) sets and exports it.
doctor_env_prefix_set=${WINEPREFIX+1}
doctor_env_prefix=${WINEPREFIX-}

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

doctor_ok=0
doctor_ng=0
doctor_skip=0
# csv result of item 6 per target (ok|ng), read by item 12 (auto_attach).
declare -A doctor_csv_state=()

# doctor_mask_home <text>
# Prints <text> on one line with the home directory shown as ~ and newlines / CRs as ?.
function doctor_mask_home() {
  local s="$1"
  local tilde='~'

  if [ -n "$HOME" ] && [ "$HOME" != / ]; then
    s=${s//"$HOME/"/"$tilde/"}
    s=${s//"$HOME "/"$tilde "}
    s=${s//"$HOME)"/"$tilde)"}
    if [[ "$s" == *"$HOME" ]]; then
      s="${s%"$HOME"}$tilde"
    fi
  fi
  s=${s//[$'\n\r']/?}
  printf '%s\n' "$s"
}

# doctor_line <OK|NG|--> <label> [<value>]
# Prints one item line and counts it. Call it in this shell, never in $(...) or after a pipe: the
# counts would be lost.
function doctor_line() {
  local state="$1" label="$2" value="${3:-}"

  if [ -n "$value" ]; then
    doctor_mask_home "$state $label $value"
  else
    doctor_mask_home "$state $label"
  fi
  case "$state" in
    OK) doctor_ok=$((doctor_ok + 1)) ;;
    NG) doctor_ng=$((doctor_ng + 1)) ;;
    *) doctor_skip=$((doctor_skip + 1)) ;;
  esac
}

# doctor_note <text>
# Prints an indented line (not counted).
function doctor_note() {
  doctor_mask_home "  $1"
}

# doctor_tail4_file <file>
# Prints ****<last 4 characters of the first line of <file>>, or only **** when the line is shorter
# than 8 characters (the last 4 would be most of it). Run it in $(...): the value never stays in a
# variable of this shell.
function doctor_tail4_file() {
  local s=''

  IFS= read -r s < "$1" 2>/dev/null
  s=${s%$'\r'}
  if [ "${#s}" -ge 8 ]; then
    s=${s: -4}
  else
    s=''
  fi
  printf '****%s' "$s"
}

# doctor_tail4_value <value>
# Same as doctor_tail4_file for a string (the heartbeat URL): atst_mask_tail4 of common.sh.
function doctor_tail4_value() {
  atst_mask_tail4 "$1"
}

# 1. Wine on PATH: only its version is asked (nothing that creates or updates a prefix).
function doctor_check_wine() {
  local v

  if command -v wine >/dev/null 2>&1 && v=$(timeout 10 wine --version 2>/dev/null); then
    v=${v%%$'\n'*}
    doctor_line OK "wine --version" "$v"
  else
    doctor_line NG "wine --version" "not found or failed"
  fi
}

# 2. The prefix in use (after ~/.atst/config) and its architecture from system.reg.
function doctor_check_arch() {
  local arch

  if [ ! -d "$WINEPREFIX" ]; then
    doctor_line NG arch "WINEPREFIX not found (WINEPREFIX=$WINEPREFIX)"
  elif [ ! -f "$WINEPREFIX/system.reg" ]; then
    doctor_line NG arch "system.reg not found (WINEPREFIX=$WINEPREFIX)"
  else
    arch=$(sed -n 's/^#arch=//p' "$WINEPREFIX/system.reg" | head -n 1 | tr -d '\r')
    doctor_line OK arch "${arch:-unknown} (WINEPREFIX=$WINEPREFIX)"
  fi
}

# 3. WINEPREFIX of (a) this shell, (b) after the config, (c) the config read without WINEPREFIX in the
# environment, which is what cron sees. (b) != (c) means the shell and cron look at different prefixes.
function doctor_check_prefix() {
  local a c

  if [ -n "$doctor_env_prefix_set" ]; then
    a=$doctor_env_prefix
  else
    a=--
  fi
  # ATST_HOME is passed as an argument, not put into the code string.
  c=$(timeout 10 bash -c 'unset WINEPREFIX WINEARCH; . "$1/common.sh" >/dev/null 2>&1; printf %s "$WINEPREFIX"' _ "$ATST_HOME" 2>/dev/null)

  if [ -n "$c" ] && [ "$WINEPREFIX" = "$c" ]; then
    doctor_line OK WINEPREFIX "env=$a config=$WINEPREFIX cron=$c"
  else
    doctor_line NG WINEPREFIX "env=$a config=$WINEPREFIX cron=${c:---}"
    doctor_note "interactive shell and cron use different WINEPREFIX; set WINEPREFIX in ~/.atst/config"
  fi
}

# 3a. The form of ~/.atst/config (atst_config_parse in lib/atst_config.sh). The old form (read as bash)
# is not NG: it is still read during the grace period. Only the key of the first line out of the
# KEY=VALUE form is shown, never the line itself (the value may be a secret, P5).
function doctor_check_config() {
  local n=${ATST_CONFIG_FORMAT_LINE:-0} i=0 l='' key='not readable'

  if [ "${ATST_CONFIG_FORMAT-}" = strict ]; then
    doctor_line OK config "KEY=VALUE 形式 (source しない)"
    return 0
  fi
  if [ "$n" -gt 0 ] 2>/dev/null; then
    key='not an assignment'
    {
      while IFS= read -r l || [ -n "$l" ]; do
        i=$((i + 1))
        if [ "$i" -eq "$n" ]; then
          if [[ $l =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            key=${BASH_REMATCH[1]}
          fi
          break
        fi
      done < "$ATST_CONFIG_FILE"
    } 2>/dev/null
  fi
  doctor_line OK config "旧形式 (bash として source). $n 行目 ($key) が KEY=VALUE 形式でない. README の「~/.atst/config の書き方」を参照"
}

# Returns 0 when some element of ATST_TARGETS selects MetaTrader <index> (atst_find_mt_index gives the
# first match only, as check_*.sh do), 1 otherwise.
function doctor_is_target_index() {
  local i="$1" t

  atst_has_targets || return 1
  for t in "${ATST_TARGETS[@]}"; do
    [ "$(atst_find_mt_index "$t")" = "$i" ] && return 0
  done
  return 1
}

# 4. ATST_TARGETS against the MetaTraders found in the prefix.
function doctor_check_targets() {
  local t idx i

  if atst_has_targets; then
    for t in "${ATST_TARGETS[@]}"; do
      idx=$(atst_find_mt_index "$t")
      if [ -z "$idx" ]; then
        doctor_line NG target "$t no MetaTrader matches"
      else
        doctor_line OK target "$t -> ${mt_name[idx]} (${mt_type[idx]})"
      fi
    done
  else
    doctor_line NG ATST_TARGETS "unset or empty"
  fi

  if [ "${#mt_name[@]}" -eq 0 ]; then
    doctor_line -- mt "none detected"
    return 0
  fi
  for i in "${!mt_name[@]}"; do
    if doctor_is_target_index "$i"; then
      doctor_note "mt ${mt_name[i]} type=${mt_type[i]} data=${mt_data[i]}"
    else
      doctor_line -- mt "${mt_name[i]} type=${mt_type[i]} not in ATST_TARGETS"
    fi
  done
}

# 5. Whether each target is running (atst_find_pid).
function doctor_check_process() {
  local t pid

  if ! atst_has_targets; then
    doctor_line -- process "no targets"
    return 0
  fi
  for t in "${ATST_TARGETS[@]}"; do
    if [ -z "$(atst_find_mt_index "$t")" ]; then
      doctor_line -- process "$t no MetaTrader matches"
      continue
    fi
    pid=$(atst_find_pid "$t")
    if [ -n "$pid" ]; then
      doctor_line OK process "$t pid=$pid"
    else
      doctor_line NG process "$t not running"
    fi
  done
}

# 6. The monitoring EA of each target and the age of its last CSV line (same rule as
# check_monitoring.sh: NG when the age reaches ATST_MONITORING_THRESHOLD).
function doctor_check_monitoring() {
  local t idx mql ea csv t_last cols elapsed th

  if ! atst_has_targets; then
    doctor_line -- ea "no targets"
    doctor_line -- csv "no targets"
    return 0
  fi

  th=${ATST_MONITORING_THRESHOLD:-180}
  if ! [[ "$th" =~ ^[0-9]+$ ]]; then
    doctor_note "ATST_MONITORING_THRESHOLD is not a number; 180 is used here"
    th=180
  fi

  for t in "${ATST_TARGETS[@]}"; do
    idx=$(atst_find_mt_index "$t")
    if [ -z "$idx" ]; then
      doctor_line -- ea "$t no MetaTrader matches"
      doctor_line -- csv "$t no MetaTrader matches"
      continue
    fi

    mql=$(atst_get_mql_folder_path "$t")
    if [ "${mt_type[idx]}" = MT4 ]; then
      ea="$mql/Experts/TerminalMonitoring.ex4"
    else
      ea="$mql/Experts/Advisors/TerminalMonitoring.ex5"
    fi
    if [ -f "$ea" ]; then
      doctor_line OK ea "$t $ea"
    else
      doctor_line NG ea "$t not found: $ea"
    fi

    csv=$(atst_get_monitoring_csv_path "$t")
    if [ ! -f "$csv" ]; then
      doctor_line NG csv "$t not found: $csv"
      doctor_csv_state["$t"]=ng
      continue
    fi
    # The field 1 and the number of fields of the last data line (14 since #158; 8 from an old EA).
    read -r t_last cols < <(tail -n 20 "$csv" | tr -d '\r' \
      | awk -F, 'NF >= 8 && $1 ~ /^[0-9]+$/ {t = $1; n = NF} END {print t, n}')
    if [ -z "$t_last" ]; then
      doctor_line NG csv "$t no data line: $csv"
      doctor_csv_state["$t"]=ng
      continue
    fi
    elapsed=$(( $(date +%s) - t_last ))
    if [ "$elapsed" -ge "$th" ]; then
      doctor_line NG csv "$t last update ${elapsed}s ago (threshold ${th}s) cols ${cols}"
      doctor_csv_state["$t"]=ng
    else
      doctor_line OK csv "$t last update ${elapsed}s ago cols ${cols}"
      doctor_csv_state["$t"]=ok
    fi
    if [ "$cols" -lt 14 ]; then
      doctor_note "the monitoring EA is old (${cols} fields): check_trade_ready.sh does not work until the EA is updated (setup_monitoring_ea.sh) and attached again"
    fi
  done
}

# 7. The form of the crontab (atst_crontab_form; comment lines do not count). Its content is not shown.
# The old-style form (wrapper.sh, removed in #176) is NG.
function doctor_check_cron() {
  local form

  form=$(atst_crontab_form)
  case "$form" in
    unknown)
      doctor_line NG "crontab -l" "failed or no crontab"
      ;;
    mixed)
      doctor_line NG "crontab -l" "mixed: both check_all.sh and wrapper.sh"
      ;;
    new)
      doctor_line OK "crontab -l" "new format (check_all.sh)"
      ;;
    legacy)
      doctor_line NG "crontab -l" "旧形式 (wrapper.sh). wrapper.sh は撤去したため旧形式の行は動きません。setup_cron.sh で移行してください (README「既存の crontab からの移行」)"
      ;;
    *)
      doctor_line NG "crontab -l" "no atst line (check_all.sh)"
      ;;
  esac
}

# 8. The last 5 headings of ~/.atst/line_error.log (shown only). The response: / message: lines hold
# notice text and are not shown.
function doctor_check_line_log() {
  local f="$ATST_CONFIG_DIR/line_error.log"
  local re='^\[[0-9-]+ [0-9:]+\] LINE send failed'
  local n l

  if [ ! -s "$f" ]; then
    doctor_line -- line_error.log "none ($f)"
    return 0
  fi
  n=$(grep -cE "$re" "$f")
  doctor_line -- line_error.log "$f: ${n:-0} failure(s), last 5:"
  while IFS= read -r l; do
    doctor_note "$l"
  done < <(grep -E "$re" "$f" | tail -n 5)
}

# 9. Secret files: existence and mode 600. The LINE ID file is never opened.
function doctor_check_secrets() {
  local name f m opt tail4

  for name in .line_token .line_id .imgbb_key; do
    f="$ATST_CONFIG_DIR/$name"
    opt=0
    [ "$name" = .imgbb_key ] && opt=1
    if [ ! -e "$f" ]; then
      if [ "$opt" -eq 1 ]; then
        doctor_line -- "$name" "not set (optional)"
      else
        doctor_line NG "$name" "not found: $f"
      fi
      continue
    fi
    m=$(stat -c %a "$f" 2>/dev/null)
    if [ "$m" != 600 ]; then
      doctor_line NG "$name" "mode ${m:-unknown} (must be 600): $f"
      continue
    fi
    if [ "$name" = .line_id ]; then
      doctor_line OK "$name" "mode 600"
    else
      tail4=$(doctor_tail4_file "$f")
      doctor_line OK "$name" "mode 600 $tail4"
    fi
  done
}

# 10. External monitoring (heartbeat.sh): which URL is in use, ~/.atst/.heartbeat_url (setup_heartbeat.sh)
# or ATST_HEARTBEAT_URL of the config (common.sh decides, ATST_HEARTBEAT_URL_FROM), shown as its last 4
# characters. .heartbeat_url not 600 is NG (same rule as item 9; not listed there, so not NG twice).
# Recommended, not required: unset is --. The URL is not contacted.
function doctor_check_heartbeat() {
  local f="$ATST_CONFIG_DIR/.heartbeat_url" m

  if [ -e "$f" ]; then
    m=$(stat -c %a "$f" 2>/dev/null)
    if [ "$m" != 600 ]; then
      doctor_line NG heartbeat "mode ${m:-unknown} (must be 600): $f"
      return 0
    fi
  fi
  case "${ATST_HEARTBEAT_URL_FROM:-}" in
    file) doctor_line OK heartbeat ".heartbeat_url=$(doctor_tail4_value "$ATST_HEARTBEAT_URL")" ;;
    config) doctor_line OK heartbeat "ATST_HEARTBEAT_URL=$(doctor_tail4_value "$ATST_HEARTBEAT_URL")" ;;
    *) doctor_line -- heartbeat "not set (recommended: run setup_heartbeat.sh)" ;;
  esac
}

# 11. The tail of ~/.atst/log/check_all.log, the stderr of the per-minute runs (shown only). The lines
# are what the checks printed; look at them before pasting into an Issue.
function doctor_check_check_all_log() {
  local f="$ATST_CONFIG_DIR/log/check_all.log"
  local m ts l

  if [ ! -s "$f" ]; then
    doctor_line -- check_all.log "none ($f)"
    return 0
  fi
  m=$(stat -c %a "$f" 2>/dev/null)
  ts=$(grep -a '^===== START ' "$f" | tail -n 1 | sed -nE 's/^===== START ([0-9-]+ [0-9:]+) pid=.*/\1/p')
  doctor_line -- check_all.log "$f: mode ${m:-unknown}, last START ${ts:-none}, last 5 lines:"
  while IFS= read -r l; do
    doctor_note "$l"
  done < <(grep -av '^===== START ' "$f" | tail -n 5)
}

# 12. The StartUp ini of mtctl.sh start (ATST_AUTO_ATTACH_EA=1, #133): whether the ini is there (mode
# 600 in drive_c/atst of mode 700) with the content of the config, and whether the running MetaTrader
# got the ini argument of atst_startup_ini_arg (MT4: the bare C:\atst\startup_<n>.ini, MT5:
# /config:C:\atst\startup_<n>.ini). Whether the EA writes the CSV is item 6 (csv); OK here with csv
# NG adds a note. Read only: the ini is neither made nor fixed, winepath / wine are not run. The
# symbol / period values, the ini content and the cmdline are not shown.
function doctor_check_auto_attach() {
  local t idx rc ini win arg dir m pid cmd cmd_u reason

  if ! atst_has_targets; then
    doctor_line -- auto_attach "no targets"
    return 0
  fi

  for t in "${ATST_TARGETS[@]}"; do
    idx=$(atst_find_mt_index "$t")
    if [ -z "$idx" ]; then
      doctor_line -- auto_attach "$t no MetaTrader matches"
      continue
    fi
    if ! atst_auto_attach_enabled; then
      doctor_line -- auto_attach "$t ATST_AUTO_ATTACH_EA=0 (manual attach)"
      continue
    fi

    atst_startup_ini_content "${mt_type[idx]}" "${ATST_AUTO_ATTACH_SYMBOL:-}" "${ATST_AUTO_ATTACH_PERIOD:-}" > /dev/null
    rc=$?
    case $rc in
      0) ;;
      2) doctor_line NG auto_attach "$t ATST_AUTO_ATTACH_SYMBOL is empty or invalid"; continue ;;
      3) doctor_line NG auto_attach "$t ATST_AUTO_ATTACH_PERIOD is empty or invalid"; continue ;;
      *) doctor_line NG auto_attach "$t unknown MetaTrader type"; continue ;;
    esac

    ini=$(atst_startup_ini_path "$t")
    win=$(atst_startup_ini_win_path "$t")
    if [ -z "$ini" ] || [ -z "$win" ]; then
      doctor_line NG auto_attach "$t WINEPREFIX not found"
      continue
    fi
    if [ ! -f "$ini" ]; then
      doctor_line NG auto_attach "$t not found: $ini"
      doctor_note "auto_attach $t: the next mtctl.sh start writes it (stop and start a running MetaTrader)"
      continue
    fi
    dir=${ini%/*}
    m=$(stat -c %a "$dir" 2>/dev/null)
    if [ "$m" != 700 ]; then
      doctor_line NG auto_attach "$t dir mode ${m:-unknown} (must be 700): $dir"
      continue
    fi
    m=$(stat -c %a "$ini" 2>/dev/null)
    if [ "$m" != 600 ]; then
      doctor_line NG auto_attach "$t mode ${m:-unknown} (must be 600): $ini"
      continue
    fi
    if ! cmp -s "$ini" <(atst_startup_ini_content "${mt_type[idx]}" "${ATST_AUTO_ATTACH_SYMBOL:-}" "${ATST_AUTO_ATTACH_PERIOD:-}"); then
      doctor_line NG auto_attach "$t content differs from the config: $ini"
      doctor_note "auto_attach $t: the next mtctl.sh start rewrites it"
      continue
    fi

    arg=$(atst_startup_ini_arg "${mt_type[idx]}" "$win")
    pid=$(atst_find_pid "$t")
    reason=""
    if [ -n "$pid" ]; then
      cmd=$(tr '\0' ' ' < "${ATST_PROC_ROOT:-/proc}/$pid/cmdline" 2>/dev/null)
      cmd_u=${cmd^^}
      # the argument as a whole word after argv[0] (separate element or joined to it)
      case $cmd_u in
        *" ${arg^^} "*|*" ${arg^^}") ;;
        *)
          case ${mt_type[idx]}:$cmd_u in
            MT4:*/CONFIG:*) reason="running with /config:, which MT4 ignores (pid=$pid)" ;;
            MT4:*) reason="running without the ini argument (pid=$pid)" ;;
            *" /CONFIG:"*) reason="running with another /config: (pid=$pid)" ;;
            *) reason="running without /config: (pid=$pid)" ;;
          esac
          ;;
      esac
      if [ -n "$reason" ]; then
        doctor_line NG auto_attach "$t $reason"
        doctor_note "auto_attach $t: mtctl.sh stop and start pass $arg"
        continue
      fi
      if [ "${mt_type[idx]}" = MT4 ]; then
        doctor_line OK auto_attach "$t ini ok, ini argument passed (pid=$pid)"
      else
        doctor_line OK auto_attach "$t ini ok, /config: passed (pid=$pid)"
      fi
    else
      doctor_line OK auto_attach "$t ini ok, not running"
    fi
    if [ "${doctor_csv_state[$t]:-}" = ng ]; then
      doctor_note "auto_attach $t: the ini is passed but no fresh CSV; the StartUp may not work (see ~/.atst/wine_$(printf '%s' "$t" | atst_to_lower).log)"
    fi
  done
}

doctor_check_wine
doctor_check_arch
doctor_check_prefix
doctor_check_config
doctor_check_targets
doctor_check_process
doctor_check_monitoring
doctor_check_cron
doctor_check_line_log
doctor_check_secrets
doctor_check_heartbeat
doctor_check_check_all_log
doctor_check_auto_attach

if [ "$doctor_ng" -eq 0 ]; then
  echo "OK summary ok=$doctor_ok ng=0 skip=$doctor_skip"
  exit 0
fi
echo "NG summary ok=$doctor_ok ng=$doctor_ng skip=$doctor_skip"
exit 1
