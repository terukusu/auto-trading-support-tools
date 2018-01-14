#!/bin/bash

. `dirname $0`/common.sh

function record_heart_beat() {
  name=$1
  path=$2
  cat "$path/MQL4/Files/heart_beat" | sed -e 's/\r//g'  | paste -s -d',' >>  "$path/MQL4/Files/heart_beat_history.csv"
}

i=0;
while [ $i -lt $TRD_NUM_TERMINALS ]; do
  name=`eval echo '$'TRD_NAME_$i`
  path=`eval echo '$'TRD_MT4_PATH_$i`

  record_heart_beat "$name" "$path"

  i=`expr $i + 1`
done
