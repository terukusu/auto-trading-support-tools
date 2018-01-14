#!/bin/bash
LOG_FILE=/home/teru/trade/data/webhook.log

echo =========== `date "+%Y-%m-%d %H:%M:%S"` ============== >> $LOG_FILE
 
set >> $LOG_FILE
cat - >> $LOG_FILE

echo "Content-type: text/plain"
echo "Connection: close"
echo ""
echo "OK"
