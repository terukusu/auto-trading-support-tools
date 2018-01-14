#!/bin/bash

. `dirname $0`/common.sh

function trd_check_order() {
  name=$1
  path=$2

  order_status_file="$path/MQL4/Files/order_status"

  if [ -s "$order_status_file" ]; then
    cat "$order_status_file" | trd_send_to_line
    rm "$order_status_file"
  fi
}

i=0;
while [ $i -lt "$TRD_NUM_TERMINALS" ]; do
  name=`eval echo '$'TRD_NAME_$i`
  path=`eval echo '$'TRD_MT4_PATH_$i`

  trd_check_order "$name" "$path"

  i=`expr $i + 1`
done
