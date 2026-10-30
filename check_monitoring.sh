#!/bin/bash
#
# モニタリング用EAが動いているか(≒MetaTraderがフリーズしていないか)を確認します。
# 異常が有れば通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

# do_check_auto_attach <name> <fullname> <last data line time, may be empty>
# ATST_AUTO_ATTACH_EA=1 (#133): MONITORING_AUTO_ATTACH_<MT> is 1 when MetaTrader has run for
# ATST_MONITORING_THRESHOLD seconds or more and no data line was written since it started (no csv, no
# data line, or only lines older than the start): the StartUp ini of mtctl.sh start did not attach the
# EA. A stopped or just started MetaTrader is not judged. Not 1: the key is closed (one 【復帰】 when
# it was 1). The notice shows the ini as C:\atst\..., never the home path or the symbol / period.
function do_check_auto_attach() {
  local target_name="$1" target_fullname="$2" last_timestamp="$3"
  local auto_key=MONITORING_AUTO_ATTACH_${target_fullname// /_}
  local target_pid et started ini_win log_name fire_msg verdict

  if ! atst_auto_attach_enabled; then
    atst_update_alert "$auto_key" 0 "" \
      "【復帰】$target_name の自動配置の確認を終了しました (ATST_AUTO_ATTACH_EA が 1 ではありません)。"
    return 0
  fi

  target_pid=$(atst_find_pid "$target_name")
  [ -n "$target_pid" ] || return 0
  et=$(ps -o etimes= -p "$target_pid" | tr -d ' ')
  [[ $et =~ ^[0-9]+$ ]] || return 0
  [ "$et" -ge "$ATST_MONITORING_THRESHOLD" ] 2>/dev/null || return 0

  started=$(( $(date +%s) - et ))
  if [ -z "$last_timestamp" ] || [ "$last_timestamp" -lt "$started" ]; then
    verdict=1
  else
    verdict=0
  fi

  ini_win=$(atst_startup_ini_win_path "$target_name")
  [ -n "$ini_win" ] || ini_win='C:\atst\startup_<name>.ini'
  log_name=$(echo $target_name | atst_to_lower)
  fire_msg="【発生】$target_name の自動配置 (ATST_AUTO_ATTACH_EA=1) が有効ですが、起動から $((et / 60)) 分たってもモニタリングデータが出ていません。/config の StartUp が効いていない可能性があります。確認: WINEPREFIX の drive_c/atst/${ini_win##*\\} ($ini_win)、~/.atst/wine_$log_name.log、doctor.sh の auto_attach"

  atst_update_alert "$auto_key" "$verdict" "$fire_msg" \
    "【復帰】$target_name の自動配置 (ATST_AUTO_ATTACH_EA=1) でモニタリングデータが出るようになりました。"
}

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file fire_msg verdict
  local now elapsed last_timestamp threshold threshold_minute target_pid

  local alert_key=MONITORING_${target_fullname// /_}

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")

  # The last complete line (8 fields); the EA may be writing the last one right now.
  if [ -f "$monitoring_file" ]; then
    last_timestamp=$(tail -n 20 "$monitoring_file" | tr -d '\r' | awk -F, 'NF >= 8 && $1 ~ /^[0-9]+$/ {t = $1} END {print t}')
  fi

  # A separate key for ATST_AUTO_ATTACH_EA=1 (#133); the checks below are unchanged.
  do_check_auto_attach "$target_name" "$target_fullname" "$last_timestamp"

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

  if [ "$last_timestamp" -eq 0 ]; then
    fire_msg="【発生】$target_name のモニタリングデータがありません。TerminalMonitoring EA がチャートに設定されていない可能性が有ります。フリーズ・Ping・スプレッド・値動きの監視が効いていません。データファイル: $monitoring_file"
  else
    fire_msg="【発生】$target_name のモニタリングデータが $threshold_minute 分以上の間更新されていません。 EAが動いていない可能性が有ります。"
  fi

  verdict=""
  if [ "$elapsed" -ge "$threshold" ]; then
    verdict=1
  elif [ "$elapsed" -lt "$threshold" ]; then
    verdict=0
  fi

  atst_update_alert "$alert_key" "$verdict" "$fire_msg" \
    "【復帰】$target_name のモニタリングデータの更新が再開しました。"
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

atst_traverse_mt do_check "${target_names[@]}"
