#!/bin/bash

. "`dirname $0`/common.sh"

minerd_path="$TRD_DIR/minerd"
count=`ps aux | grep -v grep | grep "$minerd_path" | wc -l`

if [ "$count" -lt "1" ]; then
  echo "minerdが稼働していません" | trd_send_to_line
fi

exit 0
