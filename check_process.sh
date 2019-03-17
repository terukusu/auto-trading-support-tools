#!/bin/bash

. `dirname $0`/common.sh

function trd_check_process() {
  name="$1"
  path="$2"

  terminal_win_path=`winepath -w "$path" | sed -e 's/\\\\/\\\\\\\\/g'`
  count=`ps aux | grep -v grep | grep "$terminal_win_path" | wc -l`

  if [ "$count" -lt "1" ]; then
    echo "MetaTraderプロセスが動作していません: $name" | trd_send_to_line
  fi
}

# load MT4/5 list
eval $(trd_gen_mt_list)

num_target=$#

if [ "$num_target" -le 0 ]; then
    echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
    echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
    exit 1
fi

target_names=("$@")
i=0;
while [ $i -lt $num_target ]; do
  target_name="${target_names[$i]}"
  target_path="$(trd_find_terminal "$target_name")"

  if [ -n "$target_path" ]; then
    trd_check_process "$target_name" "$target_path"
  else
    echo "チェック対象のMetaTraderのインストール場所が見つかりませ。: $target_name" | trd_send_to_line
  fi

  let i++
done
