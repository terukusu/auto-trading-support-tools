#!/bin/bash
#
# EA経由でMetaTraderのモニタリングデータを書き出しているファイルを
# 過去三日間のデータだけを残してそれより古いデータを切り捨てます。
#
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
  tmp_monitoring_file=$(basename $monitoring_file .csv)_tmp.csv

  if [ -s "$monitoring_file" ]; then
    now=$(date +%s)
    from=$(($now - 3600 * 24 * $ATST_MONITORING_TRUNCATE_BEFORE))
    cat "$monitoring_file" | awk -F, '{if ($1 > '$from') print}' > "$tmp_monitoring_file"
    mv "$tmp_monitoring_file" "$monitoring_file"
  fi

  let i++
done
