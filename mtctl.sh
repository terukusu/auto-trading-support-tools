#!/bin/bash

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# checks args

FLAG_QUIET=0

# list 時に実行ステータスを表示するかどうか。1なら表示。
FLAG_STATUS=0

function print_usage_exit() {
  echo "Usage: `basename $0` [-qsh] <list|start|status|stop|monitor> <MetaTrader Name1> [<MetaTrader Name2> ...]" 1>&2
  echo -e "\tlist: list MetaTrader installed" 1>&2
  echo -e "\tstart: start MetaTrader" 1>&2
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

function start_mt() {
  target_names=("$@")
  target_num=${#target_names[@]}

  i=0;
  while [ "$i" -lt "$target_num" ]; do
    target_name=${target_names[$i]}
    target_path=$(atst_find_terminal "$target_name")

    if [ -z "$target_path" ]; then
      pm "起動対象のMetaTraderのインストール場所が見つかりませ。起動をスキップします。: $target_name (WINEPREFIX=$WINEPREFIX)" 1>&2
      i=$((i + 1))
      continue
    fi

    pm executing: "$target_path"

    work_dir=$(winepath -w "$(dirname "$target_path")")
    wine_log=$ATST_CONFIG_DIR/wine_$(echo $target_name | atst_to_lower).log

    if [ -z "$WINE" ]; then
      WINE="$(which wine)"
    fi

    echo -e "\n===== START `date +'%Y-%m-%d %H:%M:%S'` =====" >> "$wine_log"

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

    nohup "$WINE" start /b /d "$work_dir" /unix "$target_path" "${extra_args[@]}" >> "$wine_log" 2>&1

    i=$((i + 1))
  done
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

if [ -z "$(echo "$ope" | grep -oE "START|STOP|LIST|STATUS|MONITOR")" ]; then
  print_usage_exit
fi

if [ "$ope" != "LIST" ] && [ "${#target_list[@]}" -eq "0" ]; then
  print_usage_exit
fi

if [ "$ope" == "START" ]; then
  start_mt "$@"
elif [ "$ope" == "STOP" ]; then
  stop_mt "$@"
elif [ "$ope" == "LIST" ]; then
  list_mt "$@"
elif [ "$ope" == "STATUS" ]; then
  status_mt "$@"
elif [ "$ope" == "MONITOR" ]; then
  monitor_mt "$@"
fi
