#!/bin/bash
#
# ティック (価格データ) の途絶を確認します (#137 の第 1 段)。異常が有れば通知します。
# 監視 EA の CSV の列 2 (最後のティックのサーバー時刻) が、列 1 の時刻で切った ATST_TICK_THRESHOLD 秒
# (既定 600) の窓の中で変わっていなければ TICK_<MT名> を発生、変わっていれば復帰します。
# MetaTrader も監視 EA も動いているのにティックが来ない状態 (接続断・ログアウト・口座無効・配信停止) を拾います。
# - 判定しない: CSV が無い・止まっている (ATST_MONITORING_THRESHOLD。check_monitoring.sh が通知)、
#   窓の外側に行が無い (起動直後)、窓の中に ATST_MONITORING_THRESHOLD 秒以上の空白がある (MT / 監視 EA の
#   再開直後)、列 2 が 0 の行、週末 (列 1 の UTC で金 20:00〜月 00:00。
#   ATST_TICK_WEEKEND_SKIP=0 で週末も判定)。祝日・早期クローズは抑止しません。
# - 接続・自動売買の許可は check_trade_ready.sh (#158)。
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"
  local alert_key=TICK_${target_fullname// /_}
  local monitoring_file result last1 changed outside filled now verdict=""

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")
  { [ -n "$monitoring_file" ] && [ -f "$monitoring_file" ]; } || return 0

  # The whole file in one pass (not the last N lines: the window is in seconds, not lines). Complete lines only:
  # 8 fields, field 1 a number, field 2 a positive number (0 = no tick yet / a test line). last1 is the
  # field 1 of the last complete line; the window is last1 - T <= field 1 <= last1. Printed as strings
  # (no integer format: mawk may clip it). The window must also be filled without a gap: every line in it
  # (the first one counted from the line before it) is less than M (ATST_MONITORING_THRESHOLD) seconds
  # after the previous complete line. Otherwise MetaTrader or the EA has just come back after a stop
  # and the window holds only a few lines (the csv is never cut by the EA), so it is not judged.
  result=$(tr -d '\r' < "$monitoring_file" | awk -F, -v T="$tick_threshold" -v M="$mon_threshold" '
    NF >= 8 && $1 ~ /^[0-9]+$/ && $2 ~ /^[1-9][0-9]*$/ { n++; t[n] = $1; v[n] = $2 }
    END {
      if (n == 0) exit
      last = t[n] + 0; from = last - T; inwin = 0; outside = 0; filled = 1
      for (i = 1; i <= n; i++) {
        x = t[i] + 0
        if (x < from) { outside = 1; continue }
        if (x > last) continue
        if (i > 1 && x - t[i - 1] >= M) filled = 0
        y = v[i] + 0
        if (!inwin) { mn = y; mx = y; inwin = 1 } else { if (y < mn) mn = y; if (y > mx) mx = y }
      }
      print t[n], (mn != mx ? 1 : 0), outside, filled
    }')
  read -r last1 changed outside filled <<< "$result"
  [[ "$last1" =~ ^[0-9]{1,12}$ ]] || return 0
  last1=$((10#$last1))
  now=$(date +%s)

  if [ $(( now - last1 )) -ge "$mon_threshold" ]; then
    verdict=""   # the csv itself has stopped: MONITORING_ reports it
  elif [ "$weekend_skip" -eq 1 ] && atst_is_weekend_epoch "$last1"; then
    verdict=""   # the market is closed
  elif [ "$outside" != 1 ]; then
    verdict=""   # the window is not full yet
  elif [ "$filled" != 1 ]; then
    verdict=""   # a gap in the window: just back after a stop
  elif [ "$changed" == 1 ]; then
    verdict=0
  else
    verdict=1
  fi

  atst_update_alert "$alert_key" "$verdict" \
    "【発生】$target_name の価格データ（ティック）が $(( tick_threshold / 60 )) 分以上更新されていません。ブローカーとの接続断・ログアウト・銘柄の配信停止の可能性があります（MetaTrader は動いていて監視データは更新されています）。この間は自動売買が動きません。" \
    "【復帰】$target_name の価格データ（ティック）の更新が再開しました。"
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: $(basename "$0") <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader. (ex: \"MetaTrader 4\")" 1>&2
  exit 1
fi

# The settings, once per run (at most one stderr line however many MetaTraders there are). The value is
# not printed: it would go to ~/.atst/log every minute and a value with a newline would break the line.
tick_threshold=600
if [ -n "${ATST_TICK_THRESHOLD+x}" ]; then
  if [[ "$ATST_TICK_THRESHOLD" =~ ^[1-9][0-9]{1,4}$ ]] && [ "$ATST_TICK_THRESHOLD" -ge 60 ] \
    && [ "$ATST_TICK_THRESHOLD" -le 86400 ]; then
    tick_threshold=$ATST_TICK_THRESHOLD
  else
    echo "check_tick.sh: ATST_TICK_THRESHOLD is not a number of seconds from 60 to 86400; using 600" 1>&2
  fi
fi
weekend_skip=1
[ "${ATST_TICK_WEEKEND_SKIP-}" == 0 ] && weekend_skip=0
# An invalid ATST_MONITORING_THRESHOLD is reported by doctor.sh; here the default is used silently.
mon_threshold=${ATST_MONITORING_THRESHOLD:-180}
[[ "$mon_threshold" =~ ^[1-9][0-9]{0,9}$ ]] || mon_threshold=180

atst_traverse_mt do_check "${target_names[@]}"
