#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

uptime_sec=`cat /proc/uptime | cut -d'.' -f 1`

uptime_file="$ATST_CONFIG_DIR/uptime"
uptime_sec_prev=""
# Without a previous record (first run) there is nothing to compare; just record it.
if [ -f "$uptime_file" ]; then
  uptime_sec_prev=`cat "$uptime_file" | cut -d'.' -f 1`
fi

if [ -n "$uptime_sec_prev" ] && [ "$uptime_sec" -lt "$uptime_sec_prev" ]; then
  echo "サーバーの再起動を検出しました。再起動日時: `uptime -s`" | atst_send_to_line
fi

cat /proc/uptime > "$uptime_file"
