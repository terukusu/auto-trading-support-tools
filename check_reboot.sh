#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

uptime_file="$ATST_CONFIG_DIR/uptime"
uptime_lock="$ATST_CONFIG_DIR/uptime.lock"

# An old-style crontab line and check_all.sh (#95) can run this in the same minute. Serialise
# read-compare-send-record so the later run compares with what the first one recorded. /proc/uptime is
# read only after taking the lock: read before it, the value could be smaller than the one the first
# run records afterwards and look like a reboot.
if { exec 8>> "$uptime_lock"; } 2>/dev/null; then
  if ! flock -w 35 8; then
    echo "cannot lock $uptime_lock; another run is checking for a reboot" 1>&2
    exit 1
  fi
else
  # A duplicate notice is better than none (P1).
  echo "cannot open $uptime_lock; checking without the lock" 1>&2
fi

uptime_sec=`cat /proc/uptime | cut -d'.' -f 1`

uptime_sec_prev=""
# Without a previous record (first run) there is nothing to compare; just record it.
if [ -f "$uptime_file" ]; then
  uptime_sec_prev=`cat "$uptime_file" | cut -d'.' -f 1`
fi

if [ -n "$uptime_sec_prev" ] && [ "$uptime_sec" -lt "$uptime_sec_prev" ]; then
  echo "サーバーの再起動を検出しました。再起動日時: `uptime -s`" | atst_notify_text
fi

cat /proc/uptime > "$uptime_file"
