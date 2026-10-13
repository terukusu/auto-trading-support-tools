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

# A TARGET name that matches no installed MetaTrader silently disables every check for it
# (atst_traverse_mt skips it), so report that here; this check runs every minute.
function check_target_found() {
  local target_name="$1"

  # The name is user-written (crontab); keep only safe chars so the regex-based alert_status helpers
  # can find the key again (otherwise the alert would repeat every minute).
  local alert_key=TARGET_${target_name//[^A-Za-z0-9_]/_}
  local alert_status=$(atst_get_alert_status $alert_key)

  if [ -z "$(atst_find_mt_index "$target_name")" ]; then
    if [ "$alert_status" != "1" ]; then
      echo "【発生】監視対象のMetaTraderが見つかりません。監視と自動起動が無効になっています。crontab の TARGET とインストール先のフォルダ名を確認してください: $target_name" | atst_send_to_line \
        && atst_set_alert_status $alert_key "1"
    fi
  elif [ "$alert_status" == "1" ]; then
    echo "【復帰】監視対象のMetaTraderが見つかりました: $target_name" | atst_send_to_line \
      && atst_set_alert_status $alert_key "0"
  fi
}

target_names=("$@")

if [ -z "$target_names" ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

for target_name in "${target_names[@]}"; do
  check_target_found "$target_name"
done

atst_traverse_mt do_check "${target_names[@]}"
