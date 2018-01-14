#!/bin/bash

. `dirname $0`/common.sh

function trd_check_process() {
  name=$1
  path=$2

  terminal_win_path=`winepath -w "$path/terminal.exe" | sed -e 's/\\\\/\\\\\\\\/g'`
  count=`ps aux | grep -v grep | grep "$terminal_win_path" | wc -l`

  if [ "$count" -lt "1" ]; then
    echo "MT4プロセスが動作していません: $name" | trd_send_to_line
  fi
}

i=0;
while [ $i -lt $TRD_NUM_TERMINALS ]; do
  name=`eval echo '$'TRD_NAME_$i`
  path=`eval echo '$'TRD_MT4_PATH_$i`

  trd_check_process "$name" "$path"

  i=`expr $i + 1`
done
