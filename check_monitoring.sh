#!/bin/bash
#
# モニタリング用EAが動いているか(≒MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file alert_status
  local now elapsed last_timestamp threshold threshold_minute target_pid

  local alert_key=MONITORING_${target_fullname// /_}

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  # The last complete line (8 fields); the EA may be writing the last one right now.
  if [ -f "$monitoring_file" ]; then
    last_timestamp=$(tail -n 20 "$monitoring_file" | tr -d '\r' | awk -F, 'NF >= 8 && $1 ~ /^[0-9]+$/ {t = $1} END {print t}')
  fi

  if [ -z "$last_timestamp" ]; then
    # No data at all: the EA is not attached (or was never set up) and the freeze check below would be
    # silently off. A stopped MetaTrader is reported by check_process.sh instead.
    target_pid=$(atst_find_pid "$target_name")
    if [ -z "$target_pid" ]; then
      return 0
    fi
    # Just started: the EA writes its first line some seconds after the chart opens.
    if [ "$(ps -o etimes= -p "$target_pid" | tr -d ' ')" -lt "$ATST_MONITORING_THRESHOLD" ] 2>/dev/null; then
      return 0
    fi
    last_timestamp=0
  fi

  now=$(date +%s)
  elapsed=$(($now - $last_timestamp))

  # minutes.
  threshold=$ATST_MONITORING_THRESHOLD
  threshold_minute=$(($threshold / 60))

  alert_status=$(atst_get_alert_status $alert_key)

  if [ "$alert_status" != "1" ]; then
    if [ "$elapsed" -ge "$threshold" ]; then
      if [ "$last_timestamp" -eq 0 ]; then
        echo "【発生】$target_name のモニタリングデータがありません。TerminalMonitoring EA がチャートに設定されていない可能性が有ります。フリーズ・Ping・スプレッド・値動きの監視が効いていません。データファイル: $monitoring_file" | atst_send_to_line
      else
        echo "【発生】$target_name のモニタリングデータが $threshold_minute 分以上の間更新されていません。 EAが動いていない可能性が有ります。" | atst_send_to_line
      fi

      atst_set_alert_status $alert_key 1
    fi
  else
    if [ "$elapsed" -lt "$threshold" ]; then
      echo "【復帰】$target_name のモニタリングデータの更新が再開しました。" | atst_send_to_line

      atst_set_alert_status $alert_key 0
    fi
  fi

}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

atst_traverse_mt do_check "${target_names[@]}"
