#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

target_name="$1"
if [ -z "$target_name" ]; then
  echo "Usage: `basename $0` <MetaTrader Name>" 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")' 1>&2
  exit 1
fi

target_path="$(trd_find_terminal "$target_name")"
if [ -z "$target_path" ]; then
  echo "起動対象のMetaTraderのインストール場所が見つかりませ。: $target_name" 1>&2
  exit 1
fi

work_dir="$(winepath -w "$(dirname "$target_path")")"

if [ -z "$WINE" ]; then
  WINE="$(which wine)"
fi

echo -e "\n===== START `date +'%Y-%m-%d %H:%M:%S'` =====" >> "$wine_log"

nohup "$WINE" start /b /d "$work_dir" /unix "$target_path" &>> "$wine_log"

exit 0
