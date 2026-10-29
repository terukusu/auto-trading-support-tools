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
# LINE_QUOTA (1 = 80% or more) is read by heartbeat.sh every minute (/fail to the external monitor until a
# later day sees less). Unlike the other keys it is a state only, sent to nobody, so it is written here
# with atst_set_alert_status instead of atst_update_alert (P1); a failed write does not stop the report.
# Not written when the quota could not be read: the last value stays.
quota_line_state=""
if [ -n "${quota[0]}" ]; then
  if ! [[ "${quota[1]}" =~ ^[1-9][0-9]*$ ]]; then
    quota_msg="LINE 送信数(今月): ${quota[0]}通"
    quota_line_state=0
  else
    quota_msg="LINE 送信数(今月): ${quota[0]}/${quota[1]}通"
    quota_line_state=0
    if [ $((quota[0] * 100)) -ge $((quota[1] * 80)) ]; then
      quota_warning="【注意】LINE の今月の送信数が上限の8割を超えました。上限に達すると月末まで異常や約定の通知も届きません。"
      quota_line_state=1
    fi
  fi
fi
if [ "$quota_line_state" = 1 ]; then
  atst_set_alert_status LINE_QUOTA 1
elif [ "$quota_line_state" = 0 ]; then
  atst_set_alert_status LINE_QUOTA 0
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
    # Only whether a URL is set (never the URL). Not a reason to send on its own (see the condition above).
    [ -z "${ATST_HEARTBEAT_URL:-}" ] && echo "外形監視: 未設定（推奨。setup_heartbeat.sh で設定）"
  } | atst_send_to_line
fi

# Issue #135: the desktop image of the morning report became opt-in (it shows the account number and
# balance). Tell a user whose config predates ATST_IMAGE_REPORT_DESKTOP, once: atst_update_alert records
# the key only when the push succeeded (a failed one is sent again the next day). The verdict is 1 or
# empty, never 0, so there is no "recovered" notice. A line "ATST_IMAGE_REPORT_DESKTOP=" counts as set.
image_notice=""
if [ -z "${ATST_IMAGE_REPORT_DESKTOP+x}" ] && [ "${ATST_IMAGE_REPORT_TERM:-}" != "0" ]; then
  image_notice=1
fi
atst_update_alert IMAGE_REPORT_DEFAULT_CHANGED "$image_notice" "【お知らせ】デスクトップ画像の通知は既定 OFF になりました (口座番号・残高が写るため)。朝の定期レポートは文字要約 (ImgBB の API キーがあればグラフ画像も) になります。デスクトップ画像も送るには、setup_imgbb.sh で ImgBB の API キーを設定し、~/.atst/config に ATST_IMAGE_REPORT_DESKTOP=1 を書いてください。この通知は 1 度だけです。" ""
