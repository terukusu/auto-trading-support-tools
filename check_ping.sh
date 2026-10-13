#!/bin/bash
#
# EAが動いているか(MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file last_ping
  local alert_key=PING_${target_fullname// /_}

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  if [ ! -e "$monitoring_file" ]; then
    # nothing todo
    return 0
  fi

  # Only complete lines (8 fields); the EA may be writing the last one right now.
  last_ping=$(tail -n 20 "$monitoring_file" | tr -d '\r' | awk -F, 'NF >= 8 {p = $6} END {print p}')
  if ! [[ "$last_ping" =~ ^[0-9]+$ ]]; then
    # missing data is reported by check_monitoring.sh
    return 0
  fi

  local verdict=""
  if [ "$last_ping" -ge "$ATST_THRESHOLD_PING_UPPER" ]; then
    verdict=1
  fi
  if [ "$last_ping" -le "$ATST_THRESHOLD_PING_LOWER" ]; then
    # Both hold only when UPPER <= LOWER (misconfig): keep the old order (recover only while alerted).
    if [ -z "$verdict" ] || [ "$(atst_get_alert_status "$alert_key")" == "1" ]; then
      verdict=0
    fi
  fi

  atst_update_alert "$alert_key" "$verdict" \
    "【発生】$target_name のPingが $(($ATST_THRESHOLD_PING_UPPER / 1000))ms 以上の異常値になっています。現在のPing: $(($last_ping / 1000))ms" \
    "【復帰】$target_name のPingが $(($ATST_THRESHOLD_PING_LOWER / 1000))ms 以下の正常値に戻りました。現在のPing: $(($last_ping / 1000))ms"
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

atst_traverse_mt do_check "${target_names[@]}"
