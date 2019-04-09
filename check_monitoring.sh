#!/bin/bash
#
# モニタリング用EAが動いているか(≒MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file alert_status
  local now elapsed last_timestamp threshold threshold_minute

  local alert_key=MONITORING_${target_fullname// /_}

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  if [ ! -e "$monitoring_file" ]; then
    # nothing todo
    return 0
  fi

  last_timestamp=$(tail -n1 "$monitoring_file" | tr -d '\r' | cut -d',' -f1)
  now=$(date +%s)
  elapsed=$(($now - $last_timestamp))

  # minutes.
  threshold=$ATST_MONITORING_THRESHOLD
  threshold_minute=$(($threshold / 60))

  alert_status=$(atst_get_alert_status $alert_key)

  if [ "$alert_status" != "1" ]; then
    if [ "$elapsed" -ge "$threshold" ]; then
      echo "【発生】$target_name のモニタリングデータが $threshold_minute 分以上の間更新されていません。 EAが動いていない可能性が有ります。" | atst_send_to_line

      atst_set_alert_status $alert_key 1
    fi
  else
    if [ "$elapsed" -lt "$threshold" ]; then
      echo "【復帰】$target_name のモニタリングデータの更新が再開しました。" | atst_send_to_line

      atst_set_alert_status $alert_key 0
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
