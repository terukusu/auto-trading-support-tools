#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local alert_key=PROCESS_${target_fullname// /_}

  target_pid=$(atst_find_pid "$target_name")

  local verdict=""
  if [ -z "$target_pid" ]; then
    verdict=1
  elif [ -n "$target_pid" ]; then
    verdict=0
  fi

  atst_update_alert "$alert_key" "$verdict" \
    "【発生】MetaTraderプロセスが動作していません: $target_name" \
    "【復帰】MetaTraderプロセスが再開しました: $target_name"
}

# A name in ATST_TARGETS (the crontab TARGET in the old style) that matches no installed MetaTrader
# silently disables every check for it (atst_traverse_mt skips it), so report that here; this check
# runs every minute.
function check_target_found() {
  local target_name="$1"

  # The name is user-written (ATST_TARGETS, or the crontab TARGET in the old style); keep only safe
  # chars so the key stays one field of the alert_status file (spaces or commas would split it and
  # the alert would repeat every minute).
  local alert_key=TARGET_${target_name//[^A-Za-z0-9_]/_}

  local verdict
  if [ -z "$(atst_find_mt_index "$target_name")" ]; then
    verdict=1
  else
    verdict=0
  fi

  atst_update_alert "$alert_key" "$verdict" \
    "【発生】監視対象のMetaTraderが見つかりません。監視と自動起動が無効になっています。~/.atst/config の ATST_TARGETS (旧形式の crontab では TARGET) とインストール先のフォルダ名を確認してください: $target_name" \
    "【復帰】監視対象のMetaTraderが見つかりました: $target_name"
}

target_names=("$@")

if [ -z "${target_names[0]}" ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

for target_name in "${target_names[@]}"; do
  check_target_found "$target_name"
done

atst_traverse_mt do_check "${target_names[@]}"
