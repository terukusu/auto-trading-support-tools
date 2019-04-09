#!/bin/bash
#
# EAが動いているか(MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file last_price
  local minmax pip_price minmax_delta_pips sign_upper sign_lower

  local alert_key=PRICE_${target_fullname// /_}
  local alert_status=$(atst_get_alert_status $alert_key)

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  if [ ! -e "$monitoring_file" ]; then
    # nothing todo
    return 0
  fi

  from=$(($(date +%s)- 60 * 10))
  minmax=($(cat "$monitoring_file" | awk -F, 'BEGIN{min=10000; max=0} { if ($1 > '$from') { if($3 > max) max=$3; if($3 < min) min=$3 }} END{ printf("%g %g",min ,max) }'))

  if [ ${minmax[0]} == "10000" -o ${minmax[1]} == "0" ]; then
    # no data. nothing todo
    return 0
  fi

  pip_price=$(tail -n1 "$monitoring_file" | tr -d '\r' | cut -d',' -f 7)
  minmax_delta_pips=$(printf "%g" $(echo "scale=5; (${minmax[1]} - ${minmax[0]}) / $pip_price" | bc))
  sign_upper=$(echo $minmax_delta_pips - $ATST_THRESHOLD_PRICE_UPPER | bc | cut -c1)
  sign_lower=$(echo $minmax_delta_pips - $ATST_THRESHOLD_PRICE_LOWER | bc | cut -c1)

  # echo min=${minmax[0]}
  # echo max=${minmax[1]}
  # echo pip_price=$pip_price
  # echo minmax_delta_pips=$minmax_delta_pips
  # echo sign_upper=$sign_upper
  # echo sign_lower=$sign_lower
  # echo alert_status=$alert_status

  if [ "$alert_status" != "1" ]; then
    if [ "$sign_upper" != "-" ]; then
      echo "【発生】$target_name の過去10分の値幅が $ATST_THRESHOLD_PRICE_UPPER pips 以上の異常値になっています。高値:${minmax[1]}, 安値:${minmax[0]}, 10分値幅: $minmax_delta_pips pips" | atst_send_to_line

      atst_set_alert_status $alert_key "1"
    fi
  else
    if [ "$sign_lower" == "-" ]; then
      echo "【復帰】$target_name の過去10分の値幅が $ATST_THRESHOLD_PRICE_LOWER pips 以下の正常値に戻りました。高値: ${minmax[1]}, 安値: ${minmax[0]}, 10分値幅: $minmax_delta_pips pips" | atst_send_to_line

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

atst_traverse_mt do_check_price "${target_names[@]}"
