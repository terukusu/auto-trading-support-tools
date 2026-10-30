#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

target_names=("$@")
target_num=${#target_names[@]}

if [ "$target_num" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

# check_all.sh starts this twice a minute, about 30 seconds apart. If a
# send is slow (LINE timeout is 30s) the next run would read the same file and notify twice; let only
# one run work at a time.
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
  local failed_file="${pending_file%.pending}.failed"
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

    printf '%s' "$chunk" | atst_send_to_line
    case "${PIPESTATUS[1]}" in
      0) ;;
      2)
        # LINE will never accept this chunk; retrying it would hold back every later order. Keep it in
        # a file and tell the user (a short message without the content). If even that is refused, the
        # cause is not this chunk (e.g. a wrong .line_id, also a 400): keep it pending for a retry.
        echo "約定通知 (${n} 行) を LINE が受け付けませんでした。内容は次のファイルに保存しました: $failed_file" | atst_send_to_line \
          || return 1
        printf '%s' "$chunk" >> "$failed_file" || return 1
        ;;
      *) return 1 ;;
    esac

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
    i=$((i + 1))
    continue
  fi
  order_status_file="$(atst_get_mql_folder_path "$target_name")/Files/order_status"
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

  i=$((i + 1))
done
