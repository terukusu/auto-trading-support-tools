#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

target_names=("$@")
target_num=${#target_names[@]}

if [ "$target_num" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

i=0;
while [ "$i" -lt "$target_num" ]; do
  target_name=${target_names[$i]}

  target_pid=$(atst_find_pid "$target_name")

  if [ -z "$target_pid" ]; then
    echo "MetaTraderプロセスが動作していません: $target_name" | atst_send_to_line
  fi

  let i++
done
