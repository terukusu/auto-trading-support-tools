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

  target_index=$(trd_find_mt_index "$target_name")
  target_path=${mt_home[$target_index]}
  target_type=${mt_type[$target_index]}
  if [ "$target_type" == "MT4" ]; then
    target_mq_folder="MQL4"
  else
    target_mq_folder="MQL5"
  fi

  order_status_file="$target_path/$target_mq_folder/Files/order_status"

  if [ -s "$order_status_file" ]; then
    cat "$order_status_file" | trd_send_to_line
    rm "$order_status_file"
  fi

  let i++
done
