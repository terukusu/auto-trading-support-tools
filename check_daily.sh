#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

# check server works
echo "稼働OK！`uptime`" | trd_send_to_line

# check upgradable package
upgradable="`apt list --upgradable 2>/dev/null | grep / | cut -d'/' -f 1`"
num_upgradable=`echo -n "$upgradable" | wc -l`

if [ "$num_upgradable" -gt "0" ]; then
  echo -e "${num_upgradable}個のアップグレード可能なパッケージが有ります。\n$upgradable" |  trd_send_to_line
fi

# check mt4 update
if [ -d "$WINEPREFIX/drive_c/ProgramData/MetaQuotes/WebInstall/mt4clw" -o -d "$WINEPREFIX/drive_c/ProgramData/MetaQuotes/WebInstall/mt5clw" ]; then
  echo "MetaTraderのアップデートが可能です" | trd_send_to_line
fi
