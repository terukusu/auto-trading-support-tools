#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"

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
    echo $@
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
      pm "起動対象のMetaTraderのインストール場所が見つかりませ。起動をスキップします。: $target_name" 1>&2
      let i++
      continue
    fi

    pm executing: "$target_path"

    work_dir=$(winepath -w "$(dirname "$target_path")")
    wine_log=$ATST_CONFIG_DIR/wine_$(echo $target_name | atst_to_lower).log

    if [ -z "$WINE" ]; then
      WINE="$(which wine)"
    fi

    echo -e "\n===== START `date +'%Y-%m-%d %H:%M:%S'` =====" >> "$wine_log"

    nohup "$WINE" start /b /d "$work_dir" /unix "$target_path" >> "$wine_log" 2>&1

    let i++
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
      pm "指定されたMetaTraderは起動していません。: $target_name" 1>&2
      let i++
      continue
    fi

    pm stopping: pid=$target_pid, $target_name
    kill $target_pid

    let i++
  done
}

function list_mt() {
  num_mt=${#mt_home[@]}

  echo $num_mt MetaTrader found.

  i=0
  while [ "$i" -lt ${#mt_home[@]} ]; do

    if [ "$FLAG_STATUS" -eq 1 ]; then
      mt_pid=$(atst_find_pid "${mt_name[$i]}")
      mt_status=" (stopped)"
      if [ -n "$mt_pid" ]; then
        mt_status=" (running)"
      fi
    fi

    echo [$(($i + 1))/$num_mt]:$mt_status type=${mt_type[$i]}, name=${mt_name[$i]}, home=${mt_home[$i]}
    let i++
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
      echo "status=running, pid=$target_pid, name=$target_name"
    else
      echo "status=stopped, pid= -, name=$target_name"
    fi

    let i++
  done
}

function monitor_mt {
  local target_name="$1"
  local monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

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

is_arg_valid=true

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
