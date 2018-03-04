#!/bin/bash

. "/home/teru/trade/common.sh"

echo "Content-type: text/plain; charset=utf-8"
echo ""
#tail -n 300 "$TRD_DATA_DIR/spread.csv" | sed -ne '1~2p'
tail -n 1500 "$TRD_DATA_DIR/spread.csv"
