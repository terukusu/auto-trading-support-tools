#!/bin/bash

. `dirname $0`/common.sh

function trd_check_heartbeat() {
  name=$1
  path=$2

  timestamp=`cat "$path/MQL4/Files/heart_beat" | sed -re ':loop;N;$!b loop;s/\r//g' | head -n 1`
  now=`date +%s`
  elapsed=`expr $now - $timestamp`

  # 3 minutes
  threshold=180
  threshold_minute=`expr $threshold / 60`

  if [ "$elapsed" -ge "$threshold" ]; then
    echo "$name のハートビートが $threshold_minute 分以上の間更新されていません。心停止から `expr $elapsed / 60` 分経過しています。 " | trd_send_to_line
  fi
}

i=0;
while [ $i -lt $TRD_NUM_TERMINALS ]; do
  name=`eval echo '$'TRD_NAME_$i`
  path=`eval echo '$'TRD_MT4_PATH_$i`

  trd_check_heartbeat "$name" "$path"

  i=`expr $i + 1`
done
