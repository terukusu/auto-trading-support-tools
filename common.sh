#!/bin/bash

ATST_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/atst_config.sh
. "$ATST_HOME/lib/atst_config.sh"
# shellcheck source=lib/atst_line.sh
. "$ATST_HOME/lib/atst_line.sh"
# shellcheck source=lib/atst_mt.sh
. "$ATST_HOME/lib/atst_mt.sh"

# alert_status は "キー,値,更新時刻(epoch)[,再通知の段階]" の行の集まり。check_* が毎分並行して更新するので、
# 更新は flock で排他し、一時ファイル経由で置き換える (sed -i と >> の競合で行が重複・欠落しないように)。
# キーは正規表現ではなく先頭列の完全一致で探す (PROCESS_X が PROCESS_X_2 に当たらないように)。
# 4 列目 (再通知の段階、#141) は atst_set_alert_stage だけが書く。atst_set_alert_status は行を
# "キー,値,現在時刻" の 3 列で置き換えるので、発生・復帰の記録で段階は消える (次の発生は 1 段目から)。
# atst_set_alert_status <key> <value>
# Returns 0 when recorded, 1 on an empty key, an empty ATST_ALERT_STATUS_FILE, or a lock/write failure.
# With an empty ATST_ALERT_STATUS_FILE (a broken ~/.atst/config) it does nothing: no stdin is read and
# no file is created (#110).
function atst_set_alert_status() {
  local key=$1
  local value=$2

  if [ -z "$key" ]; then
    echo "alert status key should not be empty" 1>&2
    return 1
  fi
  # Before the subshell: its "9>>" redirection would create ".lock" in the current directory.
  if [ -z "$ATST_ALERT_STATUS_FILE" ]; then
    echo "atst_set_alert_status: ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken); $key is not recorded" 1>&2
    return 1
  fi

  (
    flock -w 10 9 || { echo "cannot lock $ATST_ALERT_STATUS_FILE" 1>&2; exit 1; }
    local tmp
    tmp=$(mktemp "$ATST_ALERT_STATUS_FILE.XXXXXX") || exit 1
    touch "$ATST_ALERT_STATUS_FILE"
    awk -F, -v OFS=, -v k="$key" -v v="$value" -v t="$(date +%s)" '
      $1 == k { if (!done) print k, v, t; done = 1; next }
      { print }
      END { if (!done) print k, v, t }
    ' "$ATST_ALERT_STATUS_FILE" > "$tmp" && mv "$tmp" "$ATST_ALERT_STATUS_FILE" || { rm -f "$tmp"; exit 1; }
  ) 9>> "$ATST_ALERT_STATUS_FILE.lock"
}

# 指定キーの列 (2: 値, 3: 更新時刻, 4: 再通知の段階) を返す。キーが無い・列が空なら default。
function atst_get_alert_status_field() {
  local key="$1" field="$2" default="$3" found

  if [ -e "$ATST_ALERT_STATUS_FILE" ]; then
    found=$(awk -F, -v k="$key" -v f="$field" '$1 == k { print $f; exit }' "$ATST_ALERT_STATUS_FILE")
  fi
  echo "${found:-$default}"
}

function atst_get_alert_status() {
  atst_get_alert_status_field "$1" 2 "$2"
}

function atst_get_alert_status_time() {
  atst_get_alert_status_field "$1" 3 "$2"
}

# alert_status records what has been delivered to LINE, not what was observed: a key changes only
# after its message was sent. The message texts belong to the callers (check_*.sh).

# atst_alert_transition <key> <verdict>
# verdict: 1 = abnormal observed, 0 = normal observed, empty = undecided (between the thresholds).
# Prints "1" when the fire message is due (verdict 1 and state is not 1), "0" when the recover
# message is due (verdict 0 and state 1), nothing otherwise. Reads the state only; writes nothing.
# Returns 2 on an empty key or an invalid verdict.
function atst_alert_transition() {
  local key="$1" verdict="$2" state

  if [ -z "$key" ]; then
    echo "atst_alert_transition: key should not be empty" 1>&2
    return 2
  fi
  case "$verdict" in
    1|0) ;;
    '') return 0 ;;
    *)
      echo "atst_alert_transition: invalid verdict: $verdict" 1>&2
      return 2
      ;;
  esac

  state=$(atst_get_alert_status "$key")
  if [ "$verdict" == "1" ] && [ "$state" != "1" ]; then
    echo 1
  elif [ "$verdict" == "0" ] && [ "$state" == "1" ]; then
    echo 0
  fi
  return 0
}

# atst_alert_lock_file <key>
# Prints the per-key lock file shared by atst_update_alert and atst_spool_flush. Creates nothing.
# Prints nothing and returns 1 when ATST_CONFIG_DIR is empty (#110).
function atst_alert_lock_file() {
  [ -n "$ATST_CONFIG_DIR" ] || return 1
  local lock_key="${1//[^A-Za-z0-9_]/_}"
  printf '%s\n' "$ATST_CONFIG_DIR/alert_update.${lock_key:0:200}.lock"
}

# Reminders of an alert that goes on (#141)
# While a target key stays 1 (no transition), atst_update_alert sends "【継続中 <label>】<fire_msg>" once
# per stage of ATST_ALERT_REMIND_MINUTES (default 30 120 720 minutes after the fire notice was sent,
# that is the 3rd column) and records the stage sent in the 4th column (atst_set_alert_stage).

# atst_set_alert_stage <key> <stage>
# Writes <stage> (1-3) as the 4th column of the key's line when its value is 1, keeping the 1st to 3rd
# columns (the time the fire notice was sent). Same lock and temporary file as atst_set_alert_status.
# Returns 0 when recorded, 1 on an empty key, an invalid stage, an empty ATST_ALERT_STATUS_FILE, a
# lock/write failure, or when the key has no line with the value 1 (the file is then left as it was).
function atst_set_alert_stage() {
  local key=$1 stage=$2

  if [ -z "$key" ]; then
    echo "atst_set_alert_stage: key should not be empty" 1>&2
    return 1
  fi
  if ! [[ "$stage" =~ ^[1-3]$ ]]; then
    echo "atst_set_alert_stage: invalid stage: $stage" 1>&2
    return 1
  fi
  # Before the subshell: its "9>>" redirection would create ".lock" in the current directory (#110).
  if [ -z "$ATST_ALERT_STATUS_FILE" ]; then
    echo "atst_set_alert_stage: ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken); $key is not recorded" 1>&2
    return 1
  fi

  (
    flock -w 10 9 || { echo "cannot lock $ATST_ALERT_STATUS_FILE" 1>&2; exit 1; }
    local tmp rc=0
    if [ ! -e "$ATST_ALERT_STATUS_FILE" ]; then
      echo "atst_set_alert_stage: $key is not 1 in alert_status; the stage is not recorded" 1>&2
      exit 1
    fi
    tmp=$(mktemp "$ATST_ALERT_STATUS_FILE.XXXXXX") || exit 1
    awk -F, -v OFS=, -v k="$key" -v s="$stage" '
      $1 == k && !seen { seen = 1; if ($2 == "1") { print $1, $2, $3, s; done = 1; next } }
      { print }
      END { exit done ? 0 : 3 }
    ' "$ATST_ALERT_STATUS_FILE" > "$tmp" || rc=$?
    if [ "$rc" -eq 0 ]; then
      mv "$tmp" "$ATST_ALERT_STATUS_FILE" || { rm -f "$tmp"; exit 1; }
      exit 0
    fi
    rm -f "$tmp"
    if [ "$rc" -eq 3 ]; then
      echo "atst_set_alert_stage: $key is not 1 in alert_status; the stage is not recorded" 1>&2
    fi
    exit 1
  ) 9>> "$ATST_ALERT_STATUS_FILE.lock"
}

# atst_alert_remind_is_target <key>
# Returns 0 for the keys that are reminded (a stopped MT, stopped monitoring data, stopped ticks, a stuck
# runner: they do not recover by themselves), 1 otherwise. Fixed here, not in the config.
function atst_alert_remind_is_target() {
  case "$1" in
    PROCESS_*|MONITORING_*|TICK_*|RUNNER_STUCK) return 0 ;;
  esac
  return 1
}

# atst_alert_remind_minutes
# Prints the reminder stages in minutes on one line, from ATST_ALERT_REMIND_MINUTES (~/.atst/config):
# unset (no line in an existing config) gives "30 120 720"; empty or blanks only print nothing (no
# reminders); 1 to 3 numbers (1-999999) in strictly increasing order are printed as they are; anything
# else gives one line on stderr (without the value) and "30 120 720". Returns 0.
function atst_alert_remind_minutes() {
  local def="30 120 720" v prev=0
  local -a m=()

  if [ -z "${ATST_ALERT_REMIND_MINUTES+x}" ]; then
    printf '%s\n' "$def"
    return 0
  fi
  read -r -d '' -a m <<< "$ATST_ALERT_REMIND_MINUTES" || true
  [ "${#m[@]}" -gt 0 ] || return 0
  if [ "${#m[@]}" -le 3 ]; then
    for v in "${m[@]}"; do
      if ! [[ "$v" =~ ^[1-9][0-9]{0,5}$ ]] || [ "$v" -le "$prev" ]; then
        prev=-1
        break
      fi
      prev=$v
    done
    if [ "$prev" -gt 0 ]; then
      printf '%s\n' "${m[*]}"
      return 0
    fi
  fi
  echo "atst_update_alert: ATST_ALERT_REMIND_MINUTES is invalid; using $def" 1>&2
  printf '%s\n' "$def"
  return 0
}

# atst_alert_remind_due <key> <minutes> [<stage>]
# <minutes>: the output of atst_alert_remind_minutes. Reads alert_status only; writes nothing.
# Without <stage>: prints "<stage> <minutes of that stage>" for the furthest stage reached (elapsed
# since the 3rd column >= its minutes) when it is past the stage recorded in the 4th column, and
# returns 0. With <stage> (atst_spool_flush): prints the same for that stage when it is not recorded yet
# and still reached. Prints nothing and returns 1 otherwise: a key that is not a target or not 1, no
# stages, a 3rd column that is not a number or in the future (the clock went back).
function atst_alert_remind_due() {
  local key="$1" list="$2" want="${3:-}" t elapsed done_stage i best=0
  local -a m=()

  [ -n "$key" ] && atst_alert_remind_is_target "$key" || return 1
  read -r -a m <<< "$list"
  [ "${#m[@]}" -gt 0 ] && [ "${#m[@]}" -le 3 ] || return 1
  for i in "${m[@]}"; do
    [[ "$i" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
  done
  [ "$(atst_get_alert_status "$key")" == 1 ] || return 1
  t=$(atst_get_alert_status_time "$key")
  [[ "$t" =~ ^[0-9]{1,12}$ ]] || return 1
  elapsed=$(( $(date +%s) - 10#$t ))
  [ "$elapsed" -ge 0 ] || return 1
  done_stage=$(atst_get_alert_status_field "$key" 4 0)
  [[ "$done_stage" =~ ^[1-3]$ ]] || done_stage=0

  if [ -n "$want" ]; then
    [[ "$want" =~ ^[1-3]$ ]] && [ "$want" -le "${#m[@]}" ] && [ "$done_stage" -lt "$want" ] || return 1
    [ "$elapsed" -ge "$(( m[want - 1] * 60 ))" ] || return 1
    printf '%s %s\n' "$want" "${m[want - 1]}"
    return 0
  fi
  for i in "${!m[@]}"; do
    if [ "$elapsed" -ge "$(( m[i] * 60 ))" ]; then
      best=$(( i + 1 ))
    fi
  done
  [ "$best" -gt "$done_stage" ] || return 1
  printf '%s %s\n' "$best" "${m[best - 1]}"
}

# atst_alert_remind_text <fire_msg> <minutes>
# Prints fire_msg with its leading 【発生】 replaced by 【継続中 <label>】 (put in front when there is no
# 【発生】), without a trailing newline. The label is "<H> 時間" when <minutes> is a multiple of 60,
# "<M> 分" otherwise.
function atst_alert_remind_text() {
  local msg="$1" min="$2" label

  if [ "$(( min % 60 ))" -eq 0 ]; then
    label="$(( min / 60 )) 時間"
  else
    label="$min 分"
  fi
  msg=${msg#【発生】}
  printf '%s' "【継続中 $label】$msg"
}

# atst_update_alert <key> <verdict> <fire_msg> <recover_msg>
# Sends fire_msg or recover_msg (one push) when atst_alert_transition says so, and records the new
# state only when the send succeeded, so a failed send is tried again on the next run.
# Without a transition, a target key (atst_alert_remind_is_target) still 1 with verdict 1 gets one
# reminder per stage reached (atst_alert_remind_due, the furthest one only), under the same contract:
# decided again inside the per-key lock or spooled, and its stage recorded only after a successful send.
# Inside a check_all.sh run (a valid ATST_NOTIFY_SPOOL, see atst_spool_dir) a due notice is added to
# the run's spool instead (no lock, no send, no record; returns 0) and atst_spool_flush decides again,
# sends it with the other notices of the run in one push and records it when that push succeeded.
# Returns 0 when nothing was due or both the send and the record succeeded, 1 when the send or the
# record failed or the per-key lock was not free within 35 seconds, or a notice was due while
# ATST_ALERT_STATUS_FILE is empty (nothing sent, nothing recorded, one line in line_error.log; #110),
# 2 on invalid arguments (nothing sent, nothing recorded).
function atst_update_alert() {
  if [ "$#" -ne 4 ]; then
    echo "Usage: atst_update_alert <key> <verdict> <fire_msg> <recover_msg>" 1>&2
    return 2
  fi

  local key="$1" verdict="$2" fire_msg="$3" recover_msg="$4"
  local transition msg remind="" mins=""

  transition=$(atst_alert_transition "$key" "$verdict") || return 2
  if [ -z "$transition" ]; then
    # No transition: a reminder (#141), only for a target key still 1 with verdict 1. Without
    # ATST_ALERT_STATUS_FILE (#110) nothing is due, as before. ATST_ALERT_REMIND_MINUTES is read here
    # only, once per call (its warning is one line), and passed to the decision inside the lock.
    if ! { [ "$verdict" == 1 ] && [ -n "$ATST_ALERT_STATUS_FILE" ] && atst_alert_remind_is_target "$key"; }; then
      return 0
    fi
    mins=$(atst_alert_remind_minutes)
    remind=$(atst_alert_remind_due "$key" "$mins") || return 0
    msg=$(atst_alert_remind_text "$fire_msg" "${remind#* }")
    if atst_spool_add "$key" "1:remind=${remind%% *}" "$msg"; then
      return 0
    fi
  else
    # Inside a check_all.sh run (#96) the notice goes to the run's spool and atst_spool_flush decides
    # again, sends and records it. When it cannot be spooled, go on and send it now (P1).
    if [ "$transition" == "1" ]; then
      msg="$fire_msg"
    else
      msg="$recover_msg"
    fi
    # The state cannot be recorded (#110): sending would repeat the same notice every run. Leave a trace
    # in line_error.log, as cron drops stderr (P1).
    if [ -z "$ATST_ALERT_STATUS_FILE" ]; then
      echo "atst_update_alert: ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken); $key is not sent" 1>&2
      atst_log_line_error no_alert_status "ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken)" "$msg"
      return 1
    fi
    if atst_spool_add "$key" "$verdict" "$msg"; then
      return 0
    fi
  fi

  # An old-style crontab line and check_all.sh (#95) can see the same transition at the same time and
  # would both send it. Serialise decide-send-record per key and decide again inside the lock, so the
  # later run reads the state the first one recorded. Only a due transition or a due reminder takes the lock: the usual
  # "nothing to send" path stays as cheap as before, and other keys are never held up.
  local lock
  lock=$(atst_alert_lock_file "$key")

  (
    if { exec 8>> "$lock"; } 2>/dev/null; then
      if ! flock -w 35 8; then
        # The holder is handling this very key; leave it to the next run (nothing sent or recorded).
        echo "atst_update_alert: cannot lock $lock; $key is left for the next run" 1>&2
        exit 1
      fi
      if [ -n "$remind" ]; then
        # A reminder is decided again by its stage only, never as a transition (#141): a recovery or a
        # stage recorded meanwhile leaves nothing to send.
        remind=$(atst_alert_remind_due "$key" "$mins") || exit 0
        msg=$(atst_alert_remind_text "$fire_msg" "${remind#* }")
      else
        transition=$(atst_alert_transition "$key" "$verdict") || exit 2
        if [ -z "$transition" ]; then
          exit 0
        fi
      fi
    else
      # A duplicate notice is better than none (P1).
      echo "atst_update_alert: cannot open $lock; sending without the lock" 1>&2
    fi

    if [ -z "$remind" ]; then
      if [ "$transition" == "1" ]; then
        msg="$fire_msg"
      else
        msg="$recover_msg"
      fi
    fi

    if ! printf '%s\n' "$msg" | atst_send_to_line; then
      exit 1
    fi
    if [ -n "$remind" ]; then
      atst_set_alert_stage "$key" "${remind%% *}" || exit 1
    else
      atst_set_alert_status "$key" "$transition" || exit 1
    fi
    exit 0
  )
}

# Notices of one check_all.sh run (#96)
# LINE counts one push as one message however many texts it holds (the free plan has 200 a month), so
# check_all.sh collects the notices of a run in a spool and sends them together:
#   atst_spool_begin -> the checks (atst_update_alert / atst_notify_text add items) -> atst_spool_flush
#   -> atst_spool_end.
# The spool is $ATST_CONFIG_DIR/check_all.spool/run.<epoch>.<runner pid>/, one file per notice named
# <6-digit sequence>.<random>: line 1 = key (empty for a text-only notice), line 2 = verdict (1/0,
# "1:remind=<1-3>" for a reminder of that stage (#141), empty for a text-only notice), the rest = the text. Only check_all.sh sets ATST_NOTIFY_SPOOL; any
# other run (a check started directly or by wrapper.sh, send_to_line.sh) sends at once as before.
# atst_send_to_line always sends at once (check_order.sh needs its result to clear .pending).

# atst_spool_dir
# Prints ATST_NOTIFY_SPOOL and returns 0 when it is the spool of a running check_all.sh: exactly
# "$ATST_CONFIG_DIR/check_all.spool/run.<digits>.<digits>", an existing directory owned by us, neither
# it nor check_all.spool a symlink. Otherwise prints nothing and returns 1 (the caller sends at once).
function atst_spool_dir() {
  local dir="${ATST_NOTIFY_SPOOL-}" root="$ATST_CONFIG_DIR/check_all.spool"

  [ -n "$dir" ] && [ -n "$ATST_CONFIG_DIR" ] || return 1
  case "$dir" in
    "$root"/*) ;;
    *) return 1 ;;
  esac
  [[ "${dir#"$root"/}" =~ ^run\.[0-9]+\.[0-9]+$ ]] || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  printf '%s\n' "$dir"
}

# atst_spool_add <key> <verdict> <text>
# Adds one notice to the spool (key and verdict both empty for a text-only notice). Written to a
# temporary ".tmp.*" file and renamed, so a check killed half way leaves no broken item.
# Returns 0 when added, 1 when not (no valid spool: silently; a bad key or verdict or a failed write:
# with one line on stderr). On 1 the caller sends the notice at once.
function atst_spool_add() {
  local key="$1" verdict="$2" text="$3"
  local dir tmp f n last=0

  dir=$(atst_spool_dir) || return 1
  if [ "$#" -ne 3 ]; then
    echo "Usage: atst_spool_add <key> <verdict> <text>" 1>&2
    return 1
  fi
  case "$key" in
    *$'\n'*|*$'\r'*)
      echo "atst_spool_add: the key has a line break; not spooled" 1>&2
      return 1
      ;;
  esac
  case "$verdict" in
    1|0|''|1:remind=[1-3]) ;;
    *)
      echo "atst_spool_add: invalid verdict: $verdict; not spooled" 1>&2
      return 1
      ;;
  esac
  if [ -z "$key" ] && [ -n "$verdict" ]; then
    echo "atst_spool_add: a verdict without a key; not spooled" 1>&2
    return 1
  fi

  if ! tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null); then
    echo "atst_spool_add: cannot write to $dir; not spooled" 1>&2
    return 1
  fi
  if ! printf '%s\n%s\n%s' "$key" "$verdict" "$text" > "$tmp"; then
    rm -f -- "$tmp"
    echo "atst_spool_add: cannot write $tmp; not spooled" 1>&2
    return 1
  fi

  # The next number after the largest one. 10#: "000008" is not octal.
  for f in "$dir"/[0-9]*; do
    n=${f##*/}
    n=${n%%.*}
    [[ "$n" =~ ^[0-9]{1,9}$ ]] || continue
    if [ "$(( 10#$n ))" -gt "$last" ]; then
      last=$(( 10#$n ))
    fi
  done
  if ! mv -- "$tmp" "$dir/$(printf '%06d' $(( last + 1 ))).${tmp##*/.tmp.}" 2>/dev/null; then
    rm -f -- "$tmp"
    echo "atst_spool_add: cannot rename $tmp; not spooled" 1>&2
    return 1
  fi
  return 0
}

# atst_notify_text
# Sends the text read from stdin like atst_send_to_line (without images), or adds it to the spool of the
# running check_all.sh run. Returns 0 when spooled, otherwise atst_send_to_line's return value.
function atst_notify_text() {
  local msg
  msg=$(cat -)
  if atst_spool_add '' '' "$msg"; then
    return 0
  fi
  printf '%s\n' "$msg" | atst_send_to_line
}

# atst_spool_begin
# For check_all.sh, holding its lock: removes what an earlier run left (it never sends that), creates
# this run's spool (mode 700) and exports ATST_NOTIFY_SPOOL for the checks. Returns 1 with one line on
# stderr and ATST_NOTIFY_SPOOL unset when the spool cannot be made (every notice is then sent at once).
function atst_spool_begin() {
  # Not "${ATST_CONFIG_DIR:?}": it ends a non-interactive shell, and check_all.sh would run no check.
  if [ -z "$ATST_CONFIG_DIR" ]; then
    echo "atst_spool_begin: ATST_CONFIG_DIR is empty; notices of this run are sent one by one" 1>&2
    unset ATST_NOTIFY_SPOOL
    return 1
  fi
  local root="$ATST_CONFIG_DIR/check_all.spool" run

  run="$root/run.$(date +%s).$$"
  rm -rf -- "${root:?}" 2>/dev/null
  if ! ( umask 077; mkdir -p -- "$root" && mkdir -- "$run" ) 2>/dev/null; then
    echo "atst_spool_begin: cannot create $run; notices of this run are sent one by one" 1>&2
    unset ATST_NOTIFY_SPOOL
    return 1
  fi
  export ATST_NOTIFY_SPOOL="$run"
  if ! atst_spool_dir >/dev/null; then
    echo "atst_spool_begin: $run is not usable; notices of this run are sent one by one" 1>&2
    unset ATST_NOTIFY_SPOOL
    return 1
  fi
  return 0
}

# atst_spool_end
# For check_all.sh at the end of a run: removes the spool and unsets ATST_NOTIFY_SPOOL. Returns 0 (a
# spool left behind is removed by the next run's atst_spool_begin).
function atst_spool_end() {
  # Nothing to remove: atst_spool_begin made no spool without ATST_CONFIG_DIR.
  if [ -z "$ATST_CONFIG_DIR" ]; then
    unset ATST_NOTIFY_SPOOL
    return 0
  fi
  local root="$ATST_CONFIG_DIR/check_all.spool"

  if ! rm -rf -- "${root:?}"; then
    echo "atst_spool_end: cannot remove $root; the next run removes it" 1>&2
  fi
  unset ATST_NOTIFY_SPOOL
  return 0
}

# atst_spool_flush <max_pushes>
# For check_all.sh: sends the notices in the spool, in the order they were added, in as few pushes as
# LINE allows, and records the keyed ones of each push that succeeded. In order:
# - The last notice of a key wins; earlier ones of the same key are dropped.
# - Takes the per-key locks of atst_update_alert (in spool order, each lock file once), waiting 10
#   seconds in all for every lock of this flush. A key whose lock is not free is left for the next run
#   (not sent, not recorded). Decides again inside the lock: a transition another run (an old-style
#   crontab line) has sent and recorded meanwhile is not sent again. A reminder (#141) is sent only
#   while the key is still 1, its stage is not recorded yet and still reached; only its stage is recorded.
# - Joins the texts with an empty line under one "【host】" heading, up to 4900 characters per message
#   and never splitting a notice (a notice longer than that alone is cut like atst_send_to_line), and
#   up to 5 messages per push. At most <max_pushes> pushes; the rest is not sent nor recorded.
# - Records the keys of a push only when it returned 200; stops at the first failed push.
# - Removes every item it read, sent or not (a keyed notice still due is spooled again next run).
# - A keyed notice is neither sent nor recorded while ATST_ALERT_STATUS_FILE is empty (one line on
#   stderr and in line_error.log, rc 1; #110). Text-only notices are sent.
# Holds the locks until the records are written. Returns 0 when everything due was sent and recorded
# (or nothing was due, or there is no valid spool), 1 when something was left out or failed (one line
# on stderr each), 2 on an invalid <max_pushes> (does nothing).
function atst_spool_flush() {
  local max_pushes="$1" dir

  if ! [[ "$max_pushes" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: atst_spool_flush <max_pushes: 1 or more>" 1>&2
    return 2
  fi
  dir=$(atst_spool_dir) || return 0

  (
    local rc=0 f name i n key verdict text transition lockf fd deadline remain stage broken
    local mins="" mins_read=0
    local -a files=() keys=() verdicts=() texts=() send=() trans=() stages=()
    local -A last_of=() lock_state=()

    # Items in spool order. "[0-9]*" only: a ".tmp.*" file is a write that never finished.
    for f in "$dir"/[0-9]*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || exit 0
    mapfile -t files < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)

    for f in "${files[@]}"; do
      name=${f##*/}
      key="" verdict="" text="" stage=0 broken=0
      if ! [[ "$name" =~ ^[0-9]+\.[A-Za-z0-9]+$ ]] || [ ! -f "$f" ] || [ -L "$f" ] \
        || ! { IFS= read -r key && IFS= read -r verdict && text=$(cat); } < "$f"; then
        broken=1
      else
        # A reminder (#141) is verdict 1 at a stage.
        if [[ "$verdict" =~ ^1:remind=([1-3])$ ]]; then
          stage=${BASH_REMATCH[1]}
          verdict=1
        fi
        if { [ -n "$key" ] && [ "$verdict" != 1 ] && [ "$verdict" != 0 ]; } \
          || { [ -z "$key" ] && [ -n "$verdict" ]; }; then
          broken=1
        fi
      fi
      if [ "$broken" == 1 ]; then
        echo "atst_spool_flush: skipping a broken item: $name" 1>&2
        rc=1
        continue
      fi
      i=${#keys[@]}
      keys+=("$key")
      verdicts+=("$verdict")
      texts+=("$text")
      send+=(1)
      trans+=("")
      stages+=("$stage")
      [ -z "$key" ] || last_of["$key"]=$i
    done

    # Locks and the decision again, in spool order.
    deadline=$(( $(date +%s%3N) + 10000 ))
    for i in "${!keys[@]}"; do
      key=${keys[$i]}
      [ -n "$key" ] || continue
      if [ "${last_of[$key]}" != "$i" ]; then
        send[$i]=0
        continue
      fi
      # The state cannot be recorded (#110): do not send what would be sent again every run.
      if [ -z "$ATST_ALERT_STATUS_FILE" ]; then
        echo "atst_spool_flush: ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken); $key is not sent" 1>&2
        atst_log_line_error no_alert_status "ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken)" "${texts[$i]}"
        send[$i]=0
        rc=1
        continue
      fi
      lockf=$(atst_alert_lock_file "$key")
      if [ -z "${lock_state[$lockf]+x}" ]; then
        if { exec {fd}>> "$lockf"; } 2>/dev/null; then
          remain=$(( deadline - $(date +%s%3N) ))
          if [ "$remain" -gt 0 ]; then
            flock -w "$(( remain / 1000 )).$(printf '%03d' $(( remain % 1000 )))" "$fd"
          else
            flock -n "$fd"
          fi
          if [ $? -eq 0 ]; then
            lock_state["$lockf"]=held
          else
            lock_state["$lockf"]=busy
          fi
        else
          # A duplicate notice is better than none (P1).
          echo "atst_spool_flush: cannot open $lockf; sending $key without the lock" 1>&2
          lock_state["$lockf"]=none
        fi
      fi
      if [ "${lock_state[$lockf]}" == busy ]; then
        echo "atst_spool_flush: cannot lock $lockf; $key is left for the next run" 1>&2
        send[$i]=0
        rc=1
        continue
      fi
      if [ "${stages[$i]}" -gt 0 ]; then
        # A reminder (#141): decided by its stage only, never as a transition (a recovery recorded
        # meanwhile must not turn it into a fire). The config is read once per flush.
        if [ "$mins_read" == 0 ]; then
          mins=$(atst_alert_remind_minutes)
          mins_read=1
        fi
        if ! atst_alert_remind_due "$key" "$mins" "${stages[$i]}" >/dev/null; then
          send[$i]=0
          continue
        fi
        trans[$i]=1
        continue
      fi
      if ! transition=$(atst_alert_transition "$key" "${verdicts[$i]}"); then
        send[$i]=0
        rc=1
        continue
      fi
      if [ -z "$transition" ]; then
        send[$i]=0
        continue
      fi
      trans[$i]=$transition
    done

    # Messages: the texts joined with an empty line, a notice never split.
    local head max_len=4900 omitted="…(以下省略)" cur="" cur_items="" one
    local -a msgs=() msg_items=()
    head="【$(hostname -s)】"
    for i in "${!keys[@]}"; do
      [ "${send[$i]}" == 1 ] || continue
      one="$head${texts[$i]}"
      if [ "$(atst_char_count "$one")" -gt "$max_len" ]; then
        if [ -n "$cur_items" ]; then
          msgs+=("$cur")
          msg_items+=("$cur_items")
        fi
        msgs+=("$(atst_head_chars "$one" "$((max_len - 10))")$omitted")
        msg_items+=("$i")
        cur="" cur_items=""
      elif [ -z "$cur_items" ]; then
        cur=$one
        cur_items=$i
      elif [ "$(atst_char_count "$cur"$'\n\n'"${texts[$i]}")" -le "$max_len" ]; then
        cur+=$'\n\n'"${texts[$i]}"
        cur_items+=" $i"
      else
        msgs+=("$cur")
        msg_items+=("$cur_items")
        cur=$one
        cur_items=$i
      fi
    done
    if [ -n "$cur_items" ]; then
      msgs+=("$cur")
      msg_items+=("$cur_items")
    fi

    # Pushes of up to 5 messages each.
    local p=0 first payload log_text item
    local -a group=()
    for (( first = 0; first < ${#msgs[@]}; first += 5 )); do
      if [ "$p" -ge "$max_pushes" ]; then
        echo "atst_spool_flush: more than $max_pushes push(es) of notices; the rest is left for the next run" 1>&2
        rc=1
        break
      fi
      p=$(( p + 1 ))
      group=("${msgs[@]:first:5}")
      log_text=$(printf '%s\n\n' "${group[@]}")
      if ! payload=$(atst_line_texts_payload "$ATST_LINE_ID" "${group[@]}"); then
        rc=1
        break
      fi
      if ! atst_line_post "$payload" "$log_text"; then
        echo "atst_spool_flush: sending the notices failed; they are left for the next run" 1>&2
        rc=1
        break
      fi
      for (( n = first; n < first + ${#group[@]}; n++ )); do
        for item in ${msg_items[$n]}; do
          [ -n "${keys[$item]}" ] || continue
          if [ "${stages[$item]}" -gt 0 ]; then
            atst_set_alert_stage "${keys[$item]}" "${stages[$item]}" || rc=1
          else
            atst_set_alert_status "${keys[$item]}" "${trans[$item]}" || rc=1
          fi
        done
      done
    done

    rm -f -- "${files[@]}"
    exit "$rc"
  )
}

# atst_has_targets
# Returns 0 when ATST_TARGETS (~/.atst/config) has at least one element and none of them is empty,
# 1 otherwise (unset, (), ('') or ('a' '')). A scalar counts as one element. Prints nothing.
function atst_has_targets() {
  local t

  [ "${#ATST_TARGETS[@]}" -ge 1 ] || return 1
  for t in "${ATST_TARGETS[@]}"; do
    [ -n "$t" ] || return 1
  done
  return 0
}

atst_load_mt_list
