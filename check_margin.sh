#!/bin/bash
#
# 建玉があるときの証拠金維持率を確認します (#177)。異常が有れば通知します。
# 監視 EA の CSV の最後の完全な行 (atst_monitoring_last_row: 末尾 20 行のうち列 13 が整数・列 14 が小数の
# 14 列の行) の列 13 (建玉数) と列 14 (証拠金維持率 %) で、MARGIN_<MT名> を発生・復帰させます。
# L = ATST_THRESHOLD_MARGIN_LOWER (既定 200)、U = ATST_THRESHOLD_MARGIN_UPPER (既定 300)。上から順に:
# - L が 0: 復帰 (監視を終了。状態が 1 のときだけ送られます。CSV は読みません)
# - 列 13 が 0、または列 14 が 0 (証拠金を使う建玉が無い: 建玉なし、MT4 で待機注文だけ、両建てなど): 復帰
# - 列 14 < L: 発生
# - 列 14 >= U: 復帰
# - L <= 列 14 < U: 状態を保ちます (発生と復帰の閾値を分けて、往復による通知の連発を防ぎます)
# - 判定しない: CSV が無い、完全な行が無い (8 列の古い監視 EA・書きかけの行だけ)、CSV が止まっている
#   (ATST_MONITORING_THRESHOLD。check_monitoring.sh が通知)。週末も判定します。
# L と U は整数なので、列 14 は整数部で比べます (awk の小数の解釈はロケールに依存しうるため)。
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"
  local alert_key=MARGIN_${target_fullname// /_}
  local row t n m a now verdict="" fire_msg="" rec_msg

  if [ "$lower" -eq 0 ]; then
    atst_update_alert "$alert_key" 0 "" \
      "【復帰】$target_name の証拠金維持率の監視を終了しました (ATST_THRESHOLD_MARGIN_LOWER が 0 です)。"
    return
  fi

  row=$(atst_monitoring_last_row "$(atst_get_monitoring_csv_path "$target_name")") || return 0
  read -r t n m <<< "$row"
  now=$(date +%s)
  # the csv itself has stopped: MONITORING_ reports it (a line in the future is judged)
  [ $(( now - 10#$t )) -ge "$mon_threshold" ] && return 0

  n=$((10#$n))
  a=$((10#${m%%.*}))
  rec_msg="【復帰】$target_name の証拠金維持率が ${upper}% 以上に戻りました: ${m}%。"
  if [ "$n" -eq 0 ] || { [ "$a" -eq 0 ] && [[ "${m#*.}" =~ ^0+$ ]]; }; then
    verdict=0
    rec_msg="【復帰】$target_name に証拠金を使う建玉が無くなりました（建玉 $n 件）。決済かロスカットの可能性があるので約定通知を確認してください。"
  elif [ "$a" -lt "$lower" ]; then
    verdict=1
    fire_msg="【発生】$target_name の証拠金維持率が ${lower}% を下回りました: ${m}%（建玉 $n 件。MT4 は待機注文を含みます）。このまま下がるとロスカット（強制決済）になります。"
  elif [ "$a" -ge "$upper" ]; then
    verdict=0
  fi

  atst_update_alert "$alert_key" "$verdict" "$fire_msg" "$rec_msg"
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: $(basename "$0") <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader. (ex: \"MetaTrader 4\")" 1>&2
  exit 1
fi

# The settings, once per run (at most one stderr line each however many MetaTraders there are). The value
# is not printed: it would go to ~/.atst/log every minute and a value with a newline would break the line.
# Values are checked with a regular expression before any arithmetic (an arithmetic expression would run
# a command substitution in a[$(cmd)]).
lower=200
if [ -n "${ATST_THRESHOLD_MARGIN_LOWER+x}" ]; then
  if [[ "$ATST_THRESHOLD_MARGIN_LOWER" =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
    lower=$ATST_THRESHOLD_MARGIN_LOWER
  else
    echo "check_margin.sh: ATST_THRESHOLD_MARGIN_LOWER is not an integer from 0 to 999999; using 200" 1>&2
  fi
fi
upper=300
if [ -n "${ATST_THRESHOLD_MARGIN_UPPER+x}" ]; then
  if [[ "$ATST_THRESHOLD_MARGIN_UPPER" =~ ^[1-9][0-9]{0,5}$ ]]; then
    upper=$ATST_THRESHOLD_MARGIN_UPPER
  else
    echo "check_margin.sh: ATST_THRESHOLD_MARGIN_UPPER is not an integer from 1 to 999999; using 300" 1>&2
  fi
fi
if [ "$lower" -gt 0 ] && [ "$upper" -le "$lower" ]; then
  upper=$lower
  echo "check_margin.sh: ATST_THRESHOLD_MARGIN_UPPER is not above ATST_THRESHOLD_MARGIN_LOWER; using ATST_THRESHOLD_MARGIN_LOWER for both" 1>&2
fi
# An invalid ATST_MONITORING_THRESHOLD is reported by doctor.sh; here the default is used silently.
mon_threshold=${ATST_MONITORING_THRESHOLD:-180}
[[ "$mon_threshold" =~ ^[1-9][0-9]{0,9}$ ]] || mon_threshold=180

atst_traverse_mt do_check "${target_names[@]}"
