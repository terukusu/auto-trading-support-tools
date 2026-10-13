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
if ! exec 9>> "$ATST_CONFIG_DIR/check_order.lock"; then
  echo "cannot open the lock file: $ATST_CONFIG_DIR/check_order.lock" 1>&2
  exit 1
fi
if ! flock -n 9; then
  exit 0
fi

# Sends the pending orders in chunks below LINE's text limit, removing each chunk only after LINE
# accepted it. (Orders pile up while LINE keeps failing; one big message would be cut at the limit
# and the newest orders lost.)
function send_pending_orders() {
  local pending_file="$1"
  local chunk n line tmp

  while [ -s "$pending_file" ]; do
    chunk=""
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$n" -gt 0 ] && [ $(( $(atst_char_count "$chunk") + $(atst_char_count "$line") )) -ge 4500 ]; then
        break
      fi
      chunk+="$line"$'\n'
      n=$((n + 1))
    done < "$pending_file"

    printf '%s' "$chunk" | atst_send_to_line || return 1

    tmp=$(mktemp "$pending_file.XXXXXX") || return 1
    tail -n +$((n + 1)) "$pending_file" > "$tmp" && mv "$tmp" "$pending_file"
  done
  rm -f "$pending_file"
}

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
    # The EA may have the file open right now; give it time to finish that write (it goes to the
    # moved file) before we copy and delete it.
    sleep 1
    cat "$taken_file" >> "$pending_file" && rm -f "$taken_file"
  fi

  send_pending_orders "$pending_file"

  let i++
done
