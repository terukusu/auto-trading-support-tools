#!/bin/bash
#
# EAが動いているか(MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば LINE へ通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

target_names=("$@")
target_num=${#target_names[@]}

if [ "$target_num" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

i=0;
while [ "$i" -lt "$target_num" ]; do
  target_name=${target_names[$i]}

  target_index=$(atst_find_mt_index "$target_name")
  target_path=${mt_home[$target_index]}
  target_type=${mt_type[$target_index]}
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
      echo "$target_name のモニタリングデータが $threshold_minute 分以上の間更新されていません。更新停止から $(($elapsed / 60)) 分経過しています。 EAが動いていない可能性が有ります。" | atst_send_to_line
    fi
  fi

  let i++
done
