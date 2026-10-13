#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

target_names=("$@")
target_num=${#target_names[@]}

if [ "$target_num" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

# crontab starts this twice a minute (:10 and :40). If a send is slow (LINE timeout is 30s) the next
# run would read the same file and notify twice; let only one run work at a time.
exec 9>> "$ATST_CONFIG_DIR/check_order.lock"
if ! flock -n 9; then
  exit 0
fi

i=0;
while [ "$i" -lt "$target_num" ]; do
  target_name=${target_names[$i]}

  target_index=$(atst_find_mt_index "$target_name")
  if [ -z "$target_index" ]; then
    # Not installed (reported by check_process.sh). An empty index would read mt_home[0], i.e. a
    # different MetaTrader.
    let i++
    continue
  fi
  target_path=${mt_home[$target_index]}
  target_type=${mt_type[$target_index]}
  if [ "$target_type" == "MT4" ]; then
    target_mq_folder="MQL4"
  else
    target_mq_folder="MQL5"
  fi

  order_status_file="$target_path/$target_mq_folder/Files/order_status"
  # Orders taken from order_status but not delivered yet. Kept until LINE accepts them, so a failed
  # send is retried on the next run instead of losing the notification.
  pending_file="$order_status_file.pending"

  # The EA reopens order_status by name and appends on every order, so moving it away first means
  # orders written while we send go to a new file instead of being deleted with this one.
  # A .taking left by an interrupted run is collected first so the mv below cannot overwrite it.
  taken_file="$order_status_file.taking"
  if [ -e "$taken_file" ]; then
    cat "$taken_file" >> "$pending_file" && rm -f "$taken_file"
  fi
  if [ -s "$order_status_file" ] && [ ! -e "$taken_file" ] && mv "$order_status_file" "$taken_file"; then
    cat "$taken_file" >> "$pending_file" && rm -f "$taken_file"
  fi

  if [ -s "$pending_file" ]; then
    if atst_send_to_line < "$pending_file"; then
      rm -f "$pending_file"
    fi
  fi

  let i++
done
