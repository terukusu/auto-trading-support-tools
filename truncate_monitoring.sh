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

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  if [ -s "$monitoring_file" ]; then
    now=$(date +%s)
    from=$(($now - 3600 * 24 * $ATST_MONITORING_TRUNCATE_BEFORE))
    # Next to the data (cron's working directory is $HOME, and the same name was shared by every MT).
    tmp_monitoring_file=$(mktemp "$monitoring_file.XXXXXX") || return 1
    awk -F, '{if ($1 > '$from') print}' "$monitoring_file" > "$tmp_monitoring_file" \
      && mv "$tmp_monitoring_file" "$monitoring_file" || rm -f "$tmp_monitoring_file"
  fi
}

# Wine writes to wine_*.log (mtctl.sh start) for as long as MetaTrader runs, which can be months.
# Keep the tail of a large one, dropping the preloader warnings every wine start prints on OpenVZ
# (vm.mmap_min_addr can't be lowered in the container). It is rewritten in place because wine keeps
# it open for appending.
function trim_wine_logs() {
  local log tmp
  for log in "$ATST_CONFIG_DIR"/wine_*.log; do
    [ -f "$log" ] && [ "$(stat -c %s "$log")" -gt $((2 * 1024 * 1024)) ] || continue
    tmp=$(mktemp "$log.XXXXXX") || continue
    # grep exits 1 when every line was a warning; that is still a result to write back.
    tail -c $((1024 * 1024)) "$log" | grep -av '^preloader: Warning: failed to reserve range' > "$tmp"
    if [ "${PIPESTATUS[1]}" -le 1 ]; then
      cat "$tmp" > "$log"
    fi
    rm -f "$tmp"
  done
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

atst_traverse_mt do_check "${target_names[@]}"
trim_wine_logs
