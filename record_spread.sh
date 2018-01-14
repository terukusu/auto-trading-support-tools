#!/bin/bash

. `dirname $0`/common.sh

now=`date "+%m/%d %H:%M"`
line="$now"

i=0;
while [ $i -lt $TRD_NUM_TERMINALS ]; do
  name=`eval echo '$'TRD_NAME_$i`
  path=`eval echo '$'TRD_MT4_PATH_$i`

  spread=`trd_read_file "$path/MQL4/Files/heart_beat" | tail -n 1`
  line="$line,$spread"

  i=`expr $i + 1`
done

echo "$line" >> $TRD_DATA_DIR/spread.csv
