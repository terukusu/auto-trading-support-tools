#!/bin/bash
#
# EAが動いているか(MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file last_spread from
  local alert_key=SPREAD_${target_fullname// /_}

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  if [ ! -e "$monitoring_file" ]; then
    # nothing todo
    return 0
  fi

  # 過去5分高値が異常判定対象
  from=$(($(date +%s) - 60 * 5))
  read -r last_spread <<< "$(cat "$monitoring_file" | awk -F, 'BEGIN{max=0} NF >= 8 { if ($1 > '$from') { if($5 > max) max=$5; n++ }} END{ if (n) printf("%g ",max) }')"

  if ! [[ "$last_spread" =~ ^[0-9]+$ ]]; then
    # missing data is reported by check_monitoring.sh
    return 0
  fi

  local verdict=""
  if [ "$last_spread" -ge "$ATST_THRESHOLD_SPREAD_UPPER" ]; then
    verdict=1
  fi
  if [ "$last_spread" -le "$ATST_THRESHOLD_SPREAD_LOWER" ]; then
    # Both hold only when UPPER <= LOWER (misconfig): keep the old order (recover only while alerted).
    if [ -z "$verdict" ] || [ "$(atst_get_alert_status "$alert_key")" == "1" ]; then
      verdict=0
    fi
  fi

  atst_update_alert "$alert_key" "$verdict" \
    "【発生】$target_name の5分間のスプレッド最高値が $ATST_THRESHOLD_SPREAD_UPPER 以上の異常値になっています。5分間のスプレッド最高値: $last_spread" \
    "【復帰】$target_name の5分間のスプレッド最高値が $ATST_THRESHOLD_SPREAD_LOWER 以下の正常値に戻りました。5分間のスプレッド最高値: $last_spread"
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

atst_traverse_mt do_check "${target_names[@]}"
