#!/bin/bash

. `dirname $0`/common.sh

# check server works
echo "稼働OK！`uptime`" | trd_send_to_line

# check upgradable package
sudo "$TRD_DIR/update_package.sh" > /dev/null 2>&1
upgradable="`apt list --upgradable | grep / | cut -d'/' -f 1`"
num_upgradable=`echo -n "$upgradable" | wc -l`

if [ "$num_upgradable" -gt "0" ]; then
  echo -e "${num_upgradable}個のアップグレード可能なパッケージが有ります。\n$upgradable" |  trd_send_to_line
fi

# check mt4 update
if [ -d "/home/teru/.wine/drive_c/ProgramData/MetaQuotes/WebInstall/mt4clw" ]; then
  echo "MetaTrader4のアップデートが可能です" | trd_send_to_line
fi
