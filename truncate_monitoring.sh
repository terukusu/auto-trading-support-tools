#!/bin/bash
#
# EA経由でMetaTraderのモニタリングデータを書き出しているファイルを
# 過去三日間のデータだけを残してそれより古いデータを切り捨てます。
#
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file tmp_monitoring_file now from

  monitoring_file=$(atst_get_monitoring_csv_path $target_name)
  tmp_monitoring_file=$(basename $monitoring_file .csv)_tmp.csv

  if [ -s "$monitoring_file" ]; then
    now=$(date +%s)
    from=$(($now - 3600 * 24 * $ATST_MONITORING_TRUNCATE_BEFORE))
    cat "$monitoring_file" | awk -F, '{if ($1 > '$from') print}' > "$tmp_monitoring_file"
    mv "$tmp_monitoring_file" "$monitoring_file"
  fi
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

atst_traverse_mt do_check "${target_names[@]}"
