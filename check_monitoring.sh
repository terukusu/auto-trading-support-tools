#!/bin/bash
#
# EAが動いているか(MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check_monitoring() {
  local target_name="$1"; shift
  local target_fullname="$1"; shift
  local target_path="$1"; shift
  local target_type="$1"; shift

  local target_mq_folder monitoring_file last_timestamp
  local now elapsed threshold threshold_minute

  if [ "$target_type" == "MT4" ]; then
    target_mq_folder="MQL4"
  else
    target_mq_folder="MQL5"
  fi

  monitoring_file="$target_path/$target_mq_folder/Files/terminal_monitoring.csv"

  if [ -s "$monitoring_file" ]; then
    last_timestamp=$(tail -n1 "$monitoring_file" | cut -d',' -f1)
    now=$(date +%s)
    elapsed=$(($now - $last_timestamp))

    # minutes.
    threshold=$ATST_MONITORING_THRESHOLD
    threshold_minute=$(($threshold / 60))

    if [ "$elapsed" -ge "$threshold" ]; then
      echo "$target_fullname のモニタリングデータが $threshold_minute 分以上の間更新されていません。更新停止から $(($elapsed / 60)) 分経過しています。 EAが動いていない可能性が有ります。" | atst_send_to_line
    fi
  fi
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

traverse_mt do_check_monitoring "${target_names[@]}"
