#!/bin/bash

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# checks args

FLAG_QUIET=0

# list 時に実行ステータスを表示するかどうか。1なら表示。
FLAG_STATUS=0

function print_usage_exit() {
  echo "Usage: `basename $0` [-qsh] <list|start|restart|status|stop|monitor> <MetaTrader Name1> [<MetaTrader Name2> ...]" 1>&2
  echo -e "\tlist: list MetaTrader installed" 1>&2
  echo -e "\tstart: start MetaTrader (waits first for the X display, up to ATST_X_WAIT seconds, default 120, 0: no wait)" 1>&2
  echo -e "\trestart: stop (TERM, up to 15 s; then KILL, up to 5 s) and start MetaTrader. exit 1: could not stop, 2: busy" 1>&2
  echo -e "\tstatus: print status of specified MetaTrader" 1>&2
  echo -e "\tstop: stop MetaTrader" 1>&2
  echo -e "\tmonitor: preview monitoring data file." 1>&2
  echo -e "\t<MetaTrader Name>: folder name MetaTrader  installed. It's searched in a forward match. (ex: "'"MetaTrader 4")' 1>&2
  echo -e "\t-s: when list, show running status.(slow)" 1>&2
  echo -e "\t-q: quiet mode. print nothing." 1>&2
  echo -e "\t-h: help. print this message." 1>&2
  exit 1
}

function pm () {
  if [ $FLAG_QUIET -eq 0 ]; then
    echo "$*"
  fi
}

# start_mt_startup_ini <MT name>
# ATST_AUTO_ATTACH_EA=1 (#133): writes the StartUp ini of <MT name> (atst_startup_ini_path, mode 600 in
# drive_c/atst of mode 700, replaced through a temporary file in the same directory) and sets
# start_ini_arg to the argument of atst_startup_ini_arg: the bare C:\atst\startup_<n>.ini for MT4 (MT4
# ignores /config:, checked on the real host) and /config:C:\atst\startup_<n>.ini for MT5
# (atst_to_win_path; winepath is not used, so no Z:). On any failure start_ini_arg stays empty and
# start_ini_reason says why, without the symbol / period values or the home path; MetaTrader is then
# started without the ini (fail-open, never skipped).
function start_mt_startup_ini() {
  local name="$1"
  local idx type ini prefix_l win dir rc

  start_ini_arg=""
  start_ini_reason=""

  idx=$(atst_find_mt_index "$name")
  type=""
  [ -n "$idx" ] && type=${mt_type[idx]}
  ini=$(atst_startup_ini_path "$name")
  prefix_l=$(cd "$WINEPREFIX" 2>/dev/null && pwd)
  if [ -z "$ini" ] || [ -z "$prefix_l" ]; then
    start_ini_reason="WINEPREFIX not found"
  else
    atst_startup_ini_content "$type" "${ATST_AUTO_ATTACH_SYMBOL:-}" "${ATST_AUTO_ATTACH_PERIOD:-}" > /dev/null
    rc=$?
    case $rc in
      0) ;;
      2) start_ini_reason="ATST_AUTO_ATTACH_SYMBOL is empty or invalid" ;;
      3) start_ini_reason="ATST_AUTO_ATTACH_PERIOD is empty or invalid" ;;
      *) start_ini_reason="unknown MetaTrader type" ;;
    esac
  fi

  if [ -z "$start_ini_reason" ]; then
    win=$(atst_to_win_path "$ini" "$prefix_l")
    [ -n "$win" ] || start_ini_reason="cannot convert the ini path to a C: path"
  fi

  if [ -z "$start_ini_reason" ]; then
    dir=$prefix_l/drive_c/atst
    # A symlink is not followed; a file in the way is not removed. tmp is removed only when mktemp made it.
    if [ -L "$dir" ] ||
      ! ( umask 077
          mkdir -p -- "$dir" && chmod 700 -- "$dir" || exit 1
          tmp=$(mktemp "$dir/.startup.XXXXXX") || exit 1
          if atst_startup_ini_content "$type" "${ATST_AUTO_ATTACH_SYMBOL:-}" "${ATST_AUTO_ATTACH_PERIOD:-}" > "$tmp" &&
            chmod 600 -- "$tmp" && [ ! -d "$ini" ] && mv -f -- "$tmp" "$ini"; then
            exit 0
          fi
          rm -f -- "$tmp"
          exit 1 ) 2>/dev/null; then
      start_ini_reason="cannot write drive_c/atst/${ini##*/} in WINEPREFIX"
    fi
  fi

  if [ -z "$start_ini_reason" ]; then
    start_ini_arg=$(atst_startup_ini_arg "$type" "$win")
    [ -n "$start_ini_arg" ] || start_ini_reason="unknown MetaTrader type"
  fi
}

# Set once per run by mtctl_x_wait: the X display is waited for before the first start only (#140).
MTCTL_X_WAITED=0
MTCTL_X_LIMIT=""
x_wait_result=""

# mtctl_x_wait <MT name>
# Waits until the X socket of DISPLAY (${ATST_X11_DIR:-/tmp/.X11-unix}/X<n>, <n> = what follows the last
# ':' up to a '.') exists, checking every second for up to ATST_X_WAIT seconds (unset or empty: 120,
# 0: no wait, anything but 0..600 in plain decimal: 120 and one [warn] line). Sets x_wait_result to
# "ready (<s> s)", "timeout (<limit> s)" or "skipped (<reason>)" for the wine log. Always goes on to the
# start (fail-open: a missing X never keeps MetaTrader from starting, P1); a timeout says so on stderr.
function mtctl_x_wait() {
  local name="$1" d n sock waited

  if [ -z "$MTCTL_X_LIMIT" ]; then
    MTCTL_X_LIMIT=120
    if [ -n "${ATST_X_WAIT:-}" ]; then
      if [[ "$ATST_X_WAIT" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$ATST_X_WAIT" -le 600 ]; then
        MTCTL_X_LIMIT=$ATST_X_WAIT
      else
        pm "[warn] ATST_X_WAIT is not a number of seconds from 0 to 600; using 120" 1>&2
      fi
    fi
  fi

  if [ "$MTCTL_X_LIMIT" -eq 0 ]; then
    x_wait_result="skipped (ATST_X_WAIT=0)"
    return 0
  fi
  d=${DISPLAY:-}
  n=""
  if [[ "$d" == *:* ]]; then
    n=${d##*:}
    n=${n%%.*}
  fi
  if ! [[ "$n" =~ ^[0-9]{1,5}$ ]]; then
    x_wait_result="skipped (no display number)"
    return 0
  fi
  if [ "$MTCTL_X_WAITED" -eq 1 ]; then
    x_wait_result="skipped (already waited)"
    return 0
  fi
  MTCTL_X_WAITED=1

  sock="${ATST_X11_DIR:-/tmp/.X11-unix}/X$n"
  waited=0
  while [ ! -e "$sock" ]; do
    if [ "$waited" -ge "$MTCTL_X_LIMIT" ]; then
      x_wait_result="timeout ($MTCTL_X_LIMIT s)"
      pm "[warn] X (display :$n) が $MTCTL_X_LIMIT 秒で現れないため、そのまま起動します (x_wait): $name" 1>&2
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  x_wait_result="ready ($waited s)"
}

# The path of the MT lock held on fd 6 (mtctl_lock), empty when none is held.
MTCTL_LOCK=""

# mtctl_lock <MT name>
# Takes the lock of one MetaTrader (atst_mt_lock_path, mode 600) on fd 6 without waiting, so a start /
# restart of the same MetaTrader by @reboot, a person or the opt-in self-heal never runs twice at a time.
# Returns 2 with one [busy] line when another mtctl.sh holds it. A name that matches no MetaTrader,
# no flock command or a lock file that cannot be opened go on without the lock (returns 0; the last
# with one [warn] line, no path): a start is never skipped for the lock's sake (P1).
function mtctl_lock() {
  local name="$1" lock old

  MTCTL_LOCK=""
  lock=$(atst_mt_lock_path "$name") || return 0
  command -v flock > /dev/null 2>&1 || return 0
  old=$(umask)
  umask 077
  if ! { command exec 6>> "$lock"; } 2>/dev/null; then
    umask "$old"
    pm "[warn] ロックファイルを開けません。ロック無しで続行します: $name" 1>&2
    return 0
  fi
  umask "$old"
  if ! flock -n 6; then
    exec 6>&-
    pm "[busy] ほかの mtctl.sh が起動・再起動の最中です。スキップします: $name" 1>&2
    return 2
  fi
  MTCTL_LOCK=$lock
  return 0
}

function mtctl_unlock() {
  if [ -n "$MTCTL_LOCK" ]; then
    exec 6>&-
    MTCTL_LOCK=""
  fi
}

# Whether wine is started in a new session (setsid -w, util-linux): decided once, so wine is never run
# twice. Without it (or without --wait) wine is started as before.
MTCTL_SETSID=0
if command -v setsid > /dev/null 2>&1 && LC_ALL=C setsid --help 2>&1 | grep -q -- '--wait'; then
  MTCTL_SETSID=1
fi

# start_one <MT name>
# Starts one MetaTrader (the caller holds its lock, or goes on without one). Returns 1 when it is not
# installed (one line, as before; X is not waited for), 0 when wine was run.
function start_one() {
  local target_name="$1"
  local target_path work_dir wine_log
  local -a extra_args

  target_path=$(atst_find_terminal "$target_name")

  if [ -z "$target_path" ]; then
    pm "起動対象のMetaTraderのインストール場所が見つかりませ。起動をスキップします。: $target_name (WINEPREFIX=$WINEPREFIX)" 1>&2
    return 1
  fi

  mtctl_x_wait "$target_name"

  pm executing: "$target_path"

  wine_log=$ATST_CONFIG_DIR/wine_$(echo $target_name | atst_to_lower).log
  # winepath starts wineserver (and the wine services) when none runs: fd 6 (the MT lock) is closed so
  # they never hold the lock while MetaTrader runs, and their stderr goes to the wine log, not to the
  # caller (a pipe would stay open as long as wineserver lives).
  work_dir=$(winepath -w "$(dirname "$target_path")" 2>> "$wine_log" 6>&-)

  if [ -z "$WINE" ]; then
    WINE="$(which wine)"
  fi

  echo -e "\n===== START `date +'%Y-%m-%d %H:%M:%S'` =====" >> "$wine_log"
  echo "x_wait: $x_wait_result" >> "$wine_log"

  # ATST_AUTO_ATTACH_EA=1: one more argument, the StartUp ini (MT4: the bare C:\ path, MT5:
  # /config:<path>, #133). Never skips the start.
  extra_args=()
  if atst_auto_attach_enabled; then
    start_mt_startup_ini "$target_name"
    if [ -n "$start_ini_arg" ]; then
      extra_args=("$start_ini_arg")
      echo "auto_attach: $start_ini_arg" >> "$wine_log"
    else
      pm "[warn] 自動配置 (ATST_AUTO_ATTACH_EA=1) を使わずに起動します ($start_ini_reason): $target_name" 1>&2
      echo "auto_attach: skipped ($start_ini_reason)" >> "$wine_log"
    fi
  fi

  # fd 6 (the MT lock) is not passed on: terminal.exe / wineserver would hold the lock for good. In a
  # new session, so the TERM / KILL of check_all.sh's timeout to the self-heal's process group never
  # reaches the MetaTrader it started (#140).
  if [ "$MTCTL_SETSID" -eq 1 ]; then
    nohup setsid -w "$WINE" start /b /d "$work_dir" /unix "$target_path" "${extra_args[@]}" >> "$wine_log" 2>&1 6>&-
  else
    nohup "$WINE" start /b /d "$work_dir" /unix "$target_path" "${extra_args[@]}" >> "$wine_log" 2>&1 6>&-
  fi

  # The time of this start (first line of the lock file, read by the self-heal's grace check).
  if [ -n "$MTCTL_LOCK" ]; then
    { date +%s > "$MTCTL_LOCK"; } 2>/dev/null
  fi
  return 0
}

function start_mt() {
  local name

  for name in "$@"; do
    mtctl_lock "$name" || continue
    start_one "$name"
    mtctl_unlock
  done
  return 0
}

# mtctl_wait_gone <MT name> <pid> <seconds>
# Returns 0 as soon as atst_find_pid no longer gives <pid> (gone, or another process), 1 after <seconds>.
function mtctl_wait_gone() {
  local name="$1" pid="$2" secs="$3" i=0

  while [ "$(atst_find_pid "$name")" = "$pid" ]; do
    [ "$i" -ge "$secs" ] && return 1
    sleep 1
    i=$((i + 1))
  done
  return 0
}

# restart_one <MT name>
# The caller holds the lock. Not running: starts it (0). Running: TERM, up to 15 s; still the same pid
# (checked again, so a reused pid is never hit): KILL, up to 5 s; gone: starts it (0), else one
# [error] line and no start (1).
function restart_one() {
  local name="$1" pid

  pid=$(atst_find_pid "$name")
  if [ -z "$pid" ]; then
    start_one "$name"
    return 0
  fi
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    pm "[error] プロセスを止められないため起動しません (pid=?): $name" 1>&2
    return 1
  fi

  pm "restarting: pid=$pid, $name"
  kill "$pid" 2>/dev/null
  if ! mtctl_wait_gone "$name" "$pid" 15; then
    if [ "$(atst_find_pid "$name")" = "$pid" ]; then
      kill -KILL "$pid" 2>/dev/null
    fi
    if ! mtctl_wait_gone "$name" "$pid" 5; then
      pm "[error] プロセスを止められないため起動しません (pid=$pid): $name" 1>&2
      return 1
    fi
  fi
  start_one "$name"
  return 0
}

# Exit status of restart: 1 when one could not be stopped, else 2 when one was busy, else 0.
function restart_mt() {
  local name rc failed=0 busy=0

  for name in "$@"; do
    mtctl_lock "$name"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      busy=1
      continue
    fi
    restart_one "$name" || failed=1
    mtctl_unlock
  done
  if [ "$failed" -eq 1 ]; then
    return 1
  elif [ "$busy" -eq 1 ]; then
    return 2
  fi
  return 0
}

function stop_mt() {
  target_names=("$@")
  target_num=${#target_names[@]}

  i=0;
  while [ "$i" -lt "$target_num" ]; do
    target_name=${target_names[$i]}

    target_pid=$(atst_find_pid "$target_name")

    if [ -z "$target_pid" ]; then
      pm "指定されたMetaTraderは起動していません。: $target_name (WINEPREFIX=$WINEPREFIX)" 1>&2
      i=$((i + 1))
      continue
    fi

    pm stopping: pid=$target_pid, $target_name
    kill $target_pid

    i=$((i + 1))
  done
}

function list_mt() {
  num_mt=${#mt_home[@]}

  echo "$num_mt MetaTrader found. (WINEPREFIX=$WINEPREFIX)"

  i=0
  while [ "$i" -lt ${#mt_home[@]} ]; do

    if [ "$FLAG_STATUS" -eq 1 ]; then
      mt_pid=$(atst_find_pid "${mt_name[$i]}")
      mt_status=" (stopped)"
      if [ -n "$mt_pid" ]; then
        mt_status=" (running)"
      fi
    fi

    echo [$(($i + 1))/$num_mt]:$mt_status type=${mt_type[$i]}, name=${mt_name[$i]}, home=${mt_home[$i]}, data=${mt_data[$i]}
    i=$((i + 1))
  done
}

function status_mt() {
  target_names=("$@")
  target_num=${#target_names[@]}

  i=0;
  while [ "$i" -lt "$target_num" ]; do
    target_name=${target_names[$i]}

    target_pid=$(atst_find_pid "$target_name")

    if [ -n "$target_pid" ]; then
      echo "status=running, pid=$target_pid, name=$target_name (WINEPREFIX=$WINEPREFIX)"
    else
      echo "status=stopped, pid= -, name=$target_name (WINEPREFIX=$WINEPREFIX)"
    fi

    i=$((i + 1))
  done
}

function monitor_mt {
  local target_name="$1"
  local monitoring_file
  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  if [ -z "$monitoring_file" ]; then
    echo "MetaTrader muches name not found: $target_name" 1>&2
    return 1;
  fi

  if [ ! -f "$monitoring_file" ]; then
    echo "monitoring data file not found: $monitoring_file" 1>&2
    return 1;
  fi

  echo "================================="
  echo "loading monitoring data from file: $monitoring_file"
  echo "press Ctrl+c to stop."

  echo "================================="

  tail -f "$monitoring_file"
}

while getopts qsh OPT
do
  case $OPT in
    q)  FLAG_QUIET=1
    ;;
    s)  FLAG_STATUS=1
    ;;
    h)  print_usage_exit
    ;;
    \?) print_usage_exit
    ;;
  esac
done

shift $((OPTIND - 1))

ope=$(echo "$1" | atst_to_upper)
shift

target_list=("$@")

if [ -z "$(echo "$ope" | grep -oE "RESTART|START|STOP|LIST|STATUS|MONITOR")" ]; then
  print_usage_exit
fi

if [ "$ope" != "LIST" ] && [ "${#target_list[@]}" -eq "0" ]; then
  print_usage_exit
fi

if [ "$ope" == "START" ]; then
  start_mt "$@"
elif [ "$ope" == "RESTART" ]; then
  restart_mt "$@"
  exit $?
elif [ "$ope" == "STOP" ]; then
  stop_mt "$@"
elif [ "$ope" == "LIST" ]; then
  list_mt "$@"
elif [ "$ope" == "STATUS" ]; then
  status_mt "$@"
elif [ "$ope" == "MONITOR" ]; then
  monitor_mt "$@"
fi
