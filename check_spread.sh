#!/bin/bash
#
# EAが動いているか(MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file last_spread from alert_status
  local alert_key=SPREAD_${target_fullname// /_}

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  if [ ! -e "$monitoring_file" ]; then
    # nothing todo
    return 0
  fi

  # 過去5分高値が異常判定対象
  from=$(($(date +%s) - 60 * 5))
  last_spread=($(cat "$monitoring_file" | awk -F, 'BEGIN{max=0} { if ($1 > '$from') { if($5 > max) max=$5 }} END{ printf("%g ",max) }'))

  alert_status=$(atst_get_alert_status $alert_key)

  if [ "$alert_status" != "1" ]; then
    if [ "$last_spread" -ge "$ATST_THRESHOLD_SPREAD_UPPER" ]; then
      echo "【発生】$target_name の5分間のスプレッド最高値が $ATST_THRESHOLD_SPREAD_UPPER 以上の異常値になっています。5分間のスプレッド最高値: $last_spread" | atst_send_to_line

      atst_set_alert_status $alert_key "1"
    fi
  else
    if [ "$last_spread" -le "$ATST_THRESHOLD_SPREAD_LOWER" ]; then
      echo "【復帰】$target_name の5分間のスプレッド最高値が $ATST_THRESHOLD_SPREAD_LOWER 以下の正常値に戻りました。5分間のスプレッド最高値: $last_spread" | atst_send_to_line

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
