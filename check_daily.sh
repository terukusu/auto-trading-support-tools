#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

# check server works
echo "稼働OK！`uptime`" | atst_send_to_line

# check upgradable package
upgradable=$(apt list --upgradable 2>/dev/null | grep / | cut -d'/' -f 1)
num_upgradable=$(echo "$upgradable" | wc -l)

if [ "$num_upgradable" -gt "0" ]; then
  echo -e "${num_upgradable}個のアップグレード可能なパッケージが有ります。\n$upgradable" |  atst_send_to_line
fi

# check mt update
clwdir=(
  "$WINEPREFIX/drive_c/users/$USER/Application Data/MetaQuotes/"
  "$WINEPREFIX/drive_c/ProgramData/MetaQuotes"
  "$WINEPREFIX/drive_c/Documents and Settings/All Users/Application Data/MetaQuotes"
)

update=$(for d in "${clwdir[@]}"; do find "$d" -name "mt?clw*" 2>/dev/null; done)

if [ -n "$(echo "$update" | grep -oi mt4clw/terminal.exe)" ]; then
  msg="MetaTrader 4のアップデートが可能です。"
fi

if [ -n "$(echo "$update" | grep -oi mt5)" -a -n "$(echo "$update" | grep -oi liveupdate)" ]; then
  msg="${msg}MetaTrader 5のアップデートが可能です。"
fi

if [ -n "$msg" ]; then
  echo "${msg}MetaTraderを再起動してアップデートしてください。" | atst_send_to_line
fi
