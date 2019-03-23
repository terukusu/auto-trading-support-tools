#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

# checks args

FLAG_QUIET=0

function print_usage_exit() {
  echo "Usage: `basename $0` [-qh] <start|stop|list> <MetaTrader Name1> [<MetaTrader Name2> ...]" 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")' 1>&2
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
  # load MT4/5 list
  eval $(trd_gen_mt_list)

  target_names=("$@")
  target_num=${#target_names[@]}

  i=0;
  while [ "$i" -lt "$target_num" ]; do
    target_name=${target_names[$i]}
    target_path=$(trd_find_terminal "$target_name")

    if [ -z "$target_path" ]; then
      pm "起動対象のMetaTraderのインストール場所が見つかりませ。起動をスキップします。: $target_name" 1>&2
      let i++
      continue
    fi

    pm executing: "$target_path"

    work_dir=$(winepath -w "$(dirname "$target_path")")
    wine_log=$TRD_DATA_DIR/wine_$(echo $target_name | trd_to_lower).log

    if [ -z "$WINE" ]; then
      WINE="$(which wine)"
    fi

    echo -e "\n===== START `date +'%Y-%m-%d %H:%M:%S'` =====" >> "$wine_log"

    nohup "$WINE" start /b /d "$work_dir" /unix "$target_path" >> "$wine_log" 2>&1

    let i++
  done
}

function stop_mt() {
  # load MT4/5 list
  eval $(trd_gen_mt_list)

  target_names=("$@")
  target_num=${#target_names[@]}

  i=0;
  while [ "$i" -lt "$target_num" ]; do
    target_name=${target_names[$i]}
    target_path=$(trd_find_terminal "$target_name")

    if [ -z "$target_path" ]; then
      pm "終了対象のMetaTraderのインストール場所が見つかりませ。終了をスキップします。: $target_name" 1>&2
      let i++
      continue
    fi

    target_win_path=$(winepath -w "$target_path" | sed -e 's/\\/\\\\/g')
    target_pid=$(ps ax | grep "$target_win_path" | grep -v grep | tr -s " " | cut -d " " -f1)

    if [ -z "$target_pid" ]; then
      pm "終了対象のMetaTraderは起動していません。終了をスキップします。: $target_name" 1>&2
      let i++
      continue
    fi

    pm stopping: pid=$target_pid, $target_path
    kill $target_pid

    let i++
  done
}

function list_mt() {
  eval $(trd_gen_mt_list)

  num_mt=${#mt_home[@]}

  echo $num_mt MetaTrader found.

  i=0
  while [ "$i" -lt ${#mt_home[@]} ]; do
    echo [$(($i + 1))/$num_mt]: name=${mt_name[$i]}, home=${mt_home[$i]}
    let i++
  done
}

while getopts qh OPT
do
  case $OPT in
    q)  FLAG_QUIET=1
    ;;
    h)  print_usage_exit
    ;;
    \?) print_usage_exit
    ;;
  esac
done

shift $((OPTIND - 1))

is_arg_valid=true

ope=$(echo "$1" | trd_to_upper)
shift

target_list=("$@")
if [ "$ope" != "START" -a "$ope" != "STOP"  -a "$ope" != "LIST" ]; then
  print_usage_exit
fi

if [ "$ope" == "START" -o "$ope" == "STOP" ] && [ "${#target_list[@]}" -eq "0" ]; then
  print_usage_exit
fi

if [ "$ope" == "START" ]; then
  start_mt "$@"
elif [ "$ope" == "STOP" ]; then
  stop_mt "$@"
elif [ "$ope" == "LIST" ]; then
  list_mt "$@"
fi
