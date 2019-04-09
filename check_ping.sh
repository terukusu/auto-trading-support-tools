#!/bin/bash
#
# EAが動いているか(MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file last_ping alert_status
  local alert_key=PING_${target_fullname// /_}

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  if [ ! -e "$monitoring_file" ]; then
    # nothing todo
    return 0
  fi

  last_ping=$(tail -n1 "$monitoring_file" | tr -d '\r' | cut -d',' -f 6)
  alert_status=$(atst_get_alert_status $alert_key)

  if [ "$alert_status" != "1" ]; then
    if [ "$last_ping" -ge "$ATST_THRESHOLD_PING_UPPER" ]; then
      echo "【発生】$target_name のPingが $(($ATST_THRESHOLD_PING_UPPER / 1000))ms 以上の異常値になっています。現在のPing: $(($last_ping / 1000))ms" | atst_send_to_line

      atst_set_alert_status $alert_key "1"
    fi
  else
    if [ "$last_ping" -le "$ATST_THRESHOLD_PING_LOWER" ]; then
      echo "【復帰】$target_name のPingが $(($ATST_THRESHOLD_PING_LOWER / 1000))ms 以下の正常値に戻りました。現在のPing: $(($last_ping / 1000))ms" | atst_send_to_line

      atst_set_alert_status $alert_key "0"
    fi
  fi
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

atst_random_sleep $ATST_CHECK_RANDOM_DELAY_MAX

atst_traverse_mt do_check "${target_names[@]}"
