#!/bin/bash

. "/home/teru/trade/common.sh"

i=0;
while [ $i -lt $TRD_NUM_TERMINALS ]; do
  name=`eval echo '$'TRD_NAME_$i`
  path=`eval echo '$'TRD_MT4_PATH_$i`

  i=`expr $i + 1`
done

echo "Content-type: text/plain; charset=utf-8"
echo ""
#tail -n 300 "$TRD_DATA_DIR/spread.csv" | sed -ne '1~2p'
tail -n 1500 "$TRD_DATA_DIR/spread.csv"
