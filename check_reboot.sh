#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

uptime_sec=`cat /proc/uptime | cut -d'.' -f 1`

uptime_file="$TRD_DATA_DIR/uptime"
if [ -f $uptime_file ]; then
  uptime_sec_prev=`cat "$uptime_file" | cut -d'.' -f 1`
else
  uptime_sec_prev=$(date +%s)
fi

if [ "$uptime_sec" -lt "$uptime_sec_prev" ]; then
  echo "サーバーの再起動を検出しました。再起動日時: `uptime -s`" | trd_send_to_line
fi

cat /proc/uptime > $uptime_file
