#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

target_name="$1"
if [ -z "$target_name" ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> [<MetaTrader Name2> ...]" 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")' 1>&2
  exit 1
fi

# load MT4/5 list
eval $(trd_gen_mt_list)

target_names=("$@")
target_num=${#target_names[@]}

i=0;
while [ "$i" -lt "$target_num" ]; do
  target_name="${target_names[$i]}"
  target_path="$(trd_find_terminal "$target_name")"

  if [ -z "$target_path" ]; then
    echo "起動対象のMetaTraderのインストール場所が見つかりませ。起動をスキップします。: $target_name" 1>&2
    let i++
    continue
  fi

 echo executing: "$target_path"

  work_dir="$(winepath -w "$(dirname "$target_path")")"
  wine_log="$TRD_DATA_DIR/wine_$(echo $target_name | trd_to_lower).log"
  
  if [ -z "$WINE" ]; then
    WINE="$(which wine)"
  fi
  
  echo -e "\n===== START `date +'%Y-%m-%d %H:%M:%S'` =====" >> "$wine_log"
  
  nohup "$WINE" start /b /d "$work_dir" /unix "$target_path" &>> "$wine_log"

  let i++
done

exit 0
