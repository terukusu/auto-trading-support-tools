#!/bin/bash
#
# MetaTrader が取引できる状態かを確認します (#158)。異常が有れば通知します。
# 監視 EA の CSV の列 9〜12 (ブローカーへの接続・端末の自動売買ボタン・口座の取引許可・口座の EA 取引許可) が、
# 列 1 の時刻で切った ATST_TRADE_READY_THRESHOLD 秒 (既定 300) の窓の中ですべて不良 (どれかが 0) なら
# TRADE_<MT名> を発生、すべて良好 (すべて 1) なら復帰します。混在なら状態を保ちます。
# MetaTrader も監視 EA も動き CSV も更新されているのに取引できない状態 (接続断・自動売買ボタン OFF・
# 閲覧専用のログイン・口座の EA 禁止) を拾います。取引 EA 自身の「自動売買を許可」は見えません。
# - 判定しない: CSV が無い、14 列の行が無い (監視 EA が古い。更新して載せ直すまで何もしません)、
#   CSV が止まっている (ATST_MONITORING_THRESHOLD。check_monitoring.sh が通知)、窓の外側に行が無い (起動直後)、
#   窓の中に ATST_MONITORING_THRESHOLD 秒以上の空白がある (MT / 監視 EA の再開直後)、週末 (列 1 の UTC で
#   金 20:00〜月 00:00。ATST_TRADE_READY_WEEKEND_SKIP=0 で週末も判定)。祝日は抑止しません。
# - 列 13 (建玉数) は判定に使わず、【発生】の文面の添え書き (atst_positions_note) にだけ使います。
#   列 14 (証拠金維持率) は使いません (check_margin.sh が見ます)。
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"
  local alert_key=TRADE_${target_fullname// /_}
  local monitoring_file result last1 allbad allgood outside filled f9 f10 f11 f12 now verdict="" note=""
  local -a reasons=()
  local reason r

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")
  { [ -n "$monitoring_file" ] && [ -f "$monitoring_file" ]; } || return 0

  # The whole file in one pass (the window is in seconds, not lines). Complete lines only: 14 fields or
  # more (the 8-field lines of an old EA are skipped: neither in the window nor outside it nor in the gaps),
  # field 1 a number and fields 9 to 12 each exactly 0 or 1. last1 is the field 1 of the last complete line;
  # the window is last1 - T <= field 1 <= last1. A line is bad when any of fields 9 to 12 is 0. The window
  # must be filled without a gap of M (ATST_MONITORING_THRESHOLD) seconds or more between complete lines
  # (the first one in it counted from the line before it), as in check_tick.sh: otherwise MetaTrader or the
  # EA has just come back after a stop and the window holds only the few lines written before it connected.
  # Printed as strings (no integer format: mawk may clip it). Fields 9 to 12 of the last complete line are
  # printed for the reasons.
  result=$(tr -d '\r' < "$monitoring_file" | awk -F, -v T="$trade_threshold" -v M="$mon_threshold" '
    NF >= 14 && $1 ~ /^[0-9]+$/ && $9 ~ /^[01]$/ && $10 ~ /^[01]$/ && $11 ~ /^[01]$/ && $12 ~ /^[01]$/ {
      n++; t[n] = $1; b[n] = ($9 == "0" || $10 == "0" || $11 == "0" || $12 == "0") ? 1 : 0
      g9 = $9; g10 = $10; g11 = $11; g12 = $12
    }
    END {
      if (n == 0) exit
      last = t[n] + 0; from = last - T; outside = 0; filled = 1; nbad = 0; ngood = 0
      for (i = 1; i <= n; i++) {
        x = t[i] + 0
        if (x < from) { outside = 1; continue }
        if (x > last) continue
        if (i > 1 && x - t[i - 1] >= M) filled = 0
        if (b[i]) nbad++; else ngood++
      }
      print t[n], (ngood == 0 ? 1 : 0), (nbad == 0 ? 1 : 0), outside, filled, g9, g10, g11, g12
    }')
  read -r last1 allbad allgood outside filled f9 f10 f11 f12 <<< "$result"
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
  elif [ "$allbad" == 1 ]; then
    verdict=1
  elif [ "$allgood" == 1 ]; then
    verdict=0
  else
    verdict=""   # mixed: keep the state
  fi

  # The reasons, from the last complete line. While disconnected (field 9 = 0) the account fields 11 and 12
  # are not reliable, so only the connection (and the terminal button, field 10) is given.
  [ "$f9" == 0 ] && reasons+=("ブローカーに接続していません")
  [ "$f10" == 0 ] && reasons+=("端末の自動売買ボタンが OFF です")
  if [ "$f9" != 0 ]; then
    [ "$f11" == 0 ] && reasons+=("口座で取引が許可されていません（閲覧専用のログインなど）")
    [ "$f12" == 0 ] && reasons+=("口座で EA の取引が許可されていません")
  fi
  reason=""
  for r in "${reasons[@]}"; do
    reason+="${reason:+、}$r"
  done
  # the positions of the last monitoring data, for the fire message only
  [ "$verdict" == 1 ] && note=$(atst_positions_note "$target_name")

  atst_update_alert "$alert_key" "$verdict" \
    "【発生】$target_name が $(( trade_threshold / 60 )) 分以上取引できない状態です: ${reason}。この間は自動売買が動きません（MetaTrader は動いていて監視データは更新されています）。${note:+ $note}" \
    "【復帰】$target_name が取引できる状態に戻りました。"
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: $(basename "$0") <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader. (ex: \"MetaTrader 4\")" 1>&2
  exit 1
fi

# The settings, once per run (at most one stderr line however many MetaTraders there are). The value is
# not printed: it would go to ~/.atst/log every minute and a value with a newline would break the line.
trade_threshold=300
if [ -n "${ATST_TRADE_READY_THRESHOLD+x}" ]; then
  if [[ "$ATST_TRADE_READY_THRESHOLD" =~ ^[1-9][0-9]{1,4}$ ]] && [ "$ATST_TRADE_READY_THRESHOLD" -ge 60 ] \
    && [ "$ATST_TRADE_READY_THRESHOLD" -le 86400 ]; then
    trade_threshold=$ATST_TRADE_READY_THRESHOLD
  else
    echo "check_trade_ready.sh: ATST_TRADE_READY_THRESHOLD is not a number of seconds from 60 to 86400; using 300" 1>&2
  fi
fi
weekend_skip=1
[ "${ATST_TRADE_READY_WEEKEND_SKIP-}" == 0 ] && weekend_skip=0
# An invalid ATST_MONITORING_THRESHOLD is reported by doctor.sh; here the default is used silently.
mon_threshold=${ATST_MONITORING_THRESHOLD:-180}
[[ "$mon_threshold" =~ ^[1-9][0-9]{0,9}$ ]] || mon_threshold=180

atst_traverse_mt do_check "${target_names[@]}"
