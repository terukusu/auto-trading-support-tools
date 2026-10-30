#!/bin/bash
#
# Opt-in self-heal (#140). Run by check_all.sh only, last in its run, with the names of ATST_TARGETS.
# Does nothing at all unless ~/.atst/self_heal.enabled is a regular file of ours with mode 600.
#
# When enabled, starts or restarts at most one MetaTrader per run through mtctl.sh (start / restart;
# it never stops one by itself) and sends one LINE message about it:
# - PROCESS_<MT> is 1 (the 【発生】 was delivered) and no process: mtctl.sh start.
# - MONITORING_<MT> is 1 for ATST_MONITORING_THRESHOLD s or more, the process has run for twice that,
#   ATST_AUTO_ATTACH_EA=1 and MONITORING_AUTO_ATTACH_<MT> is not 1: mtctl.sh restart.
# Other keys are never acted on: a missing tick or a trading switch turned off is not mended by a
# restart. Per MetaTrader: not within 1800 s of the last try, at most 3 tries in 86400 s (then one
# 【自己修復停止】 and nothing more until the oldest try is 24 h old), not while mtctl.sh holds its lock,
# not within ATST_MONITORING_THRESHOLD s of its last start or of the boot of the OS.
# The tries are kept in ~/.atst/self_heal.log ("<epoch>,<MT>,<key>,<op>,<begin|ok|fail|halt>", 600),
# the "begin" line written before mtctl.sh is called, so a try cut off by the timeout still counts.
# alert_status is read only. Nothing on stdout; why nothing was done is one stderr line (check_all.log).
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ "$#" -eq 0 ]; then
  echo "Usage: $(basename "$0") <MetaTrader Name1> [<MetaTrader Name2> ...]  (run by check_all.sh; does nothing without ~/.atst/self_heal.enabled)" 1>&2
  exit 1
fi

# --- enabled? (before alert_status is read) ---
[ -n "${ATST_CONFIG_DIR:-}" ] || exit 0
sh_enabled="$ATST_CONFIG_DIR/self_heal.enabled"
if [ -L "$sh_enabled" ]; then
  echo "self_heal.enabled is a symlink; self-heal is OFF" 1>&2
  exit 0
fi
[ -f "$sh_enabled" ] || exit 0
sh_owner_mode=$(stat -c '%u %a' -- "$sh_enabled" 2>/dev/null)
if [ "$sh_owner_mode" != "$EUID 600" ]; then
  echo "self_heal.enabled must be owned by uid $EUID with mode 600 (now uid ${sh_owner_mode% *} mode ${sh_owner_mode#* }); self-heal is OFF" 1>&2
  exit 0
fi

# --- the record of the tries: without it nothing is done (the limits depend on it) ---
sh_log="$ATST_CONFIG_DIR/self_heal.log"
if [ -L "$sh_log" ] || { [ -e "$sh_log" ] && [ ! -f "$sh_log" ]; }; then
  echo "self_heal.log is not a regular file; self-heal does nothing" 1>&2
  exit 0
fi
# The limits are counted from this file: one that cannot be read would count as no tries at all.
if [ -e "$sh_log" ] && [ ! -r "$sh_log" ]; then
  echo "self_heal.log cannot be read; self-heal does nothing" 1>&2
  exit 0
fi

# Fixed on purpose (not in the config): the limits are the safety of this opt-in.
SH_COOLDOWN=1800
SH_WINDOW=86400
SH_MAX=3

# The grace after a start / the boot and the MONITORING_ gates: ATST_MONITORING_THRESHOLD.
sh_grace=180
if [[ "${ATST_MONITORING_THRESHOLD:-}" =~ ^[1-9][0-9]{0,4}$ ]]; then
  sh_grace=$ATST_MONITORING_THRESHOLD
fi

# Right after the boot of the OS @reboot's mtctl.sh start may not have taken its lock yet.
sh_up=""
{ read -r sh_up _ < "${ATST_PROC_ROOT:-/proc}/uptime"; } 2>/dev/null
sh_up=${sh_up%%.*}
if [[ "$sh_up" =~ ^[0-9]{1,12}$ ]] && [ "$(( 10#$sh_up ))" -lt "$sh_grace" ]; then
  echo "system started $(( 10#$sh_up )) s ago (< $sh_grace s); self-heal waits" 1>&2
  exit 0
fi

# sh_append <line>: appends one line to self_heal.log (created 600). Returns 1 when it cannot.
sh_append() {
  ( umask 077; printf '%s\n' "$1" >> "$sh_log" ) 2>/dev/null
}

# sh_stats <MT> <now>: "<begin lines within the window> <latest begin epoch> <latest halt epoch>" of <MT>.
# Lines with fewer than 5 fields or a first field that is not a number are skipped.
sh_stats() {
  if [ ! -e "$sh_log" ]; then
    echo "0 0 0"
    return 0
  fi
  awk -F, -v m="$1" -v since="$(( $2 - SH_WINDOW ))" '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 == m {
      t = $1 + 0
      if ($5 == "begin") {
        if (t > since) c++
        if (t > lb) lb = t
      } else if ($5 == "halt") {
        if (t > lh) lh = t
      }
    }
    END { printf "%d %d %d\n", c, lb, lh }
  ' "$sh_log" 2>/dev/null || echo "0 0 0"
}

sh_acted=0

# sh_one <name> <fullname> <home> <type> (atst_traverse_mt)
sh_one() {
  local name="$1" full="$2"
  local mt now pid op key what t et cnt lb lh lock rc stamp n msg

  [ "$sh_acted" -eq 1 ] && return 0

  mt=${full//[^A-Za-z0-9_]/_}
  now=$(date +%s)

  # An ATST_TARGETS name that is not installed (check_process.sh reports it).
  if [ "$(atst_get_alert_status "TARGET_${name//[^A-Za-z0-9_]/_}" 0)" = 1 ]; then
    return 0
  fi

  pid=$(atst_find_pid "$name")
  if [ "$(atst_get_alert_status "PROCESS_${full// /_}" 0)" = 1 ] && [ -z "$pid" ]; then
    op=start
    key="PROCESS_$mt"
    what="MT プロセス停止"
  elif [ "$(atst_get_alert_status "MONITORING_${full// /_}" 0)" = 1 ]; then
    if [ -z "$pid" ]; then
      echo "$full: MONITORING_ is 1 but MetaTrader is not running; nothing to restart" 1>&2
      return 0
    fi
    t=$(atst_get_alert_status_time "MONITORING_${full// /_}" "")
    if ! [[ "$t" =~ ^[0-9]{1,12}$ ]] || [ "$(( now - 10#$t ))" -lt "$sh_grace" ]; then
      echo "$full: the monitoring data has not been stopped long enough (< $sh_grace s after the notice); no restart yet" 1>&2
      return 0
    fi
    et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    if ! [[ "$et" =~ ^[0-9]{1,12}$ ]] || [ "$(( 10#$et ))" -lt "$(( sh_grace * 2 ))" ]; then
      echo "$full: MetaTrader has run less than $(( sh_grace * 2 )) s (or unknown); no restart" 1>&2
      return 0
    fi
    if ! atst_auto_attach_enabled; then
      echo "$full: ATST_AUTO_ATTACH_EA is not 1, so a restart would not bring the monitoring EA back; no restart" 1>&2
      return 0
    fi
    if [ "$(atst_get_alert_status "MONITORING_AUTO_ATTACH_${full// /_}" 0)" = 1 ]; then
      echo "$full: the StartUp ini does not work (MONITORING_AUTO_ATTACH_); no restart" 1>&2
      return 0
    fi
    op=restart
    key="MONITORING_$mt"
    what="監視データ停止"
  else
    return 0
  fi

  read -r cnt lb lh < <(sh_stats "$mt" "$now")

  # The limit first, then the cooldown.
  if [ "$cnt" -ge "$SH_MAX" ]; then
    if [ "$lh" -gt 0 ] && [ "$lh" -ge "$lb" ]; then
      echo "$full: $SH_MAX tries within 24 h; self-heal stays stopped for it (already notified)" 1>&2
      return 0
    fi
    # The halt line first: without it the notice would go out every minute.
    if sh_append "$now,$mt,$key,$op,halt"; then
      printf '%s\n' "【自己修復停止】$full: 24 時間に 3 回再起動しても直らないため、自己修復を止めています（人の確認が必要です）" | atst_notify_text
      echo "$full: $SH_MAX tries within 24 h; self-heal stopped for it" 1>&2
    else
      echo "$full: $SH_MAX tries within 24 h, but self_heal.log cannot be written; no notice" 1>&2
    fi
    return 0
  fi
  if [ "$lb" -gt "$(( now - SH_COOLDOWN ))" ]; then
    echo "$full: tried $(( now - lb )) s ago (< $SH_COOLDOWN s); waiting" 1>&2
    return 0
  fi

  # Not while mtctl.sh starts / restarts it, nor right after its last start. A lock that cannot be
  # checked means no action (an automatic operation errs on the side of doing nothing).
  lock=$(atst_mt_lock_path "$name")
  if [ -z "$lock" ]; then
    echo "$full: no lock path; nothing done" 1>&2
    return 0
  fi
  ( umask 077
    { command exec 9>> "$lock"; } 2>/dev/null || exit 2
    flock -n 9 || exit 1
    exit 0 ) 2>/dev/null
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "$full: busy (mtctl.sh is starting / restarting it); nothing done" 1>&2
    return 0
  elif [ "$rc" -ne 0 ]; then
    echo "$full: the lock cannot be checked; nothing done" 1>&2
    return 0
  fi
  stamp=$(head -n 1 "$lock" 2>/dev/null)
  if [[ "$stamp" =~ ^[0-9]{1,12}$ ]] && [ "$(( now - 10#$stamp ))" -lt "$sh_grace" ]; then
    echo "$full: started by mtctl.sh $(( now - 10#$stamp )) s ago (< $sh_grace s); waiting" 1>&2
    return 0
  fi

  if ! sh_append "$now,$mt,$key,$op,begin"; then
    echo "$full: self_heal.log cannot be written; nothing done" 1>&2
    return 0
  fi
  sh_acted=1
  n=$(( cnt + 1 ))

  bash "$ATST_HOME/mtctl.sh" -q "$op" "$name" 1>&2 < /dev/null
  rc=$?

  if [ "$rc" -eq 0 ]; then
    sh_append "$(date +%s),$mt,$key,$op,ok" || echo "$full: cannot write the result to self_heal.log" 1>&2
    if [ "$op" = start ]; then
      msg="【自己修復】$full: ${what}のため MetaTrader を起動しました (直近 24 時間で $n/3 回目)"
    else
      msg="【自己修復】$full: ${what}のため MetaTrader を再起動しました (直近 24 時間で $n/3 回目)"
    fi
  else
    sh_append "$(date +%s),$mt,$key,$op,fail" || echo "$full: cannot write the result to self_heal.log" 1>&2
    echo "$full: mtctl.sh $op exit $rc" 1>&2
    if [ "$op" = restart ] && [ "$rc" -eq 1 ]; then
      msg="【自己修復】$full: 再起動に失敗しました（プロセスを止められません。pid=$pid）(直近 24 時間で $n/3 回目)"
    elif [ "$rc" -eq 2 ]; then
      msg="【自己修復】$full: ほかの起動・再起動の最中だったため何もしませんでした (直近 24 時間で $n/3 回目)"
    elif [ "$op" = start ]; then
      msg="【自己修復】$full: 起動に失敗しました (exit $rc) (直近 24 時間で $n/3 回目)"
    else
      msg="【自己修復】$full: 再起動に失敗しました (exit $rc) (直近 24 時間で $n/3 回目)"
    fi
  fi
  printf '%s\n' "$msg" | atst_notify_text
  return 0
}

atst_traverse_mt sh_one "$@" > /dev/null
exit 0
