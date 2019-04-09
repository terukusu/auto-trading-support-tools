#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local alert_key=PROCESS_${target_fullname// /_}
  local alert_status=$(atst_get_alert_status $alert_key)

  target_pid=$(atst_find_pid "$target_name")

  if [ "$alert_status" != "1" ]; then
    if [ -z "$target_pid" ]; then
      echo "【発生】MetaTraderプロセスが動作していません: $target_name" | atst_send_to_line

      atst_set_alert_status $alert_key "1"
    fi
  else
    if [ -n "$target_pid" ]; then
      echo "【復帰】MetaTraderプロセスが再開しました: $target_name" | atst_send_to_line

      atst_set_alert_status $alert_key "0"
    fi
  fi
}

target_names=("$@")

if [ -z "$target_names" ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

atst_random_sleep $ATST_CHECK_RANDOM_DELAY_MAX

atst_traverse_mt do_check "${target_names[@]}"
