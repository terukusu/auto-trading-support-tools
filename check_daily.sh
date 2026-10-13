#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

# check upgradable package
upgradable=$(apt list --upgradable 2>/dev/null | grep / | cut -d'/' -f 1)
num_upgradable=$(echo "$upgradable" | grep -ve '^\s*$' | wc -l)

if [ "$num_upgradable" -gt "0" ]; then
  upgrade_msg="${num_upgradable}個のアップグレード可能なパッケージが有ります。"$'\n'"$upgradable"
fi

# check mt update
# Every user in the prefix: cron does not always set $USER. Newer Wine has AppData/Roaming.
clwdir=(
  "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/MetaQuotes
  "$WINEPREFIX"/drive_c/users/*/"Application Data"/MetaQuotes
  "$WINEPREFIX/drive_c/ProgramData/MetaQuotes"
  "$WINEPREFIX/drive_c/Documents and Settings/All Users/Application Data/MetaQuotes"
)

update=$(for d in "${clwdir[@]}"; do find "$d" -name "mt?clw*" 2>/dev/null; done)

if [ -n "$(echo "$update" | grep -oi mt4clw/terminal.exe)" ]; then
  msg="MetaTrader 4のアップデートが可能です。"
fi

if [ -n "$(echo "$update" | grep -oi mt5)" ] && [ -n "$(echo "$update" | grep -oi liveupdate)" ]; then
  msg="${msg}MetaTrader 5のアップデートが可能です。"
fi

if [ -n "$msg" ]; then
  mt_update_msg="${msg}MetaTraderを再起動してアップデートしてください。"
fi

# LINE's free plan sends 200 messages a month and then nothing (alerts included) until the month ends.
quota_warning=""
read -ra quota <<< "$(atst_line_quota)"
if [ -n "${quota[0]}" ]; then
  if ! [[ "${quota[1]}" =~ ^[1-9][0-9]*$ ]]; then
    quota_msg="LINE 送信数(今月): ${quota[0]}通"
  else
    quota_msg="LINE 送信数(今月): ${quota[0]}/${quota[1]}通"
    if [ $((quota[0] * 100)) -ge $((quota[1] * 80)) ]; then
      quota_warning="【注意】LINE の今月の送信数が上限の8割を超えました。上限に達すると月末まで異常や約定の通知も届きません。"
    fi
  fi
fi

# Everything in one message (one push = one of the 200). With ATST_DAILY_REPORT=0 it is sent only when
# there is something to act on.
if [ "$ATST_DAILY_REPORT" != "0" ] || [ -n "$upgrade_msg$mt_update_msg$quota_warning" ]; then
  {
    echo "稼働OK！$(uptime)"
    [ -n "$quota_msg" ] && echo "$quota_msg"
    [ -n "$quota_warning" ] && echo "$quota_warning"
    [ -n "$mt_update_msg" ] && echo "$mt_update_msg"
    [ -n "$upgrade_msg" ] && echo "$upgrade_msg"
  } | atst_send_to_line
fi
