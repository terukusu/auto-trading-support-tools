#!/bin/bash
#
# 過去 n 時間の値動きとスプレッドを MT ごとの文字要約で通知します。
# ImgBB の API キーがあればグラフ画像、さらに ATST_IMAGE_REPORT_DESKTOP=1 ならデスクトップ画像も付けます。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

# Images are collected and sent together: LINE counts one push as one message however many images it
# carries (free plan: 200 a month), and a push holds up to 4 images with the text.
report_dir=""
report_images=()
report_titles=()
# one element (several lines) per MT, sent in the first push only
report_summaries=()

# Prints the summary of one MT from terminal_monitoring.csv on stdin (CR already removed), or nothing
# when no line is newer than $1 (epoch). Line 1: spread, line 2: price, line 3: the epoch of the last
# line. Compared as numbers, printed as written in the CSV. The range in pips is computed as in
# check_price.sh ((max - min) / pip); "-" when the pip is not a positive number.
function summarize_monitoring() {
  awk -F, -v from="$1" '
    NF >= 8 && $1 > from {
      n++
      if (n == 1 || $5 + 0 < smin + 0) smin = $5
      if (n == 1 || $5 + 0 > smax + 0) smax = $5
      if (n == 1 || $3 + 0 < bmin + 0) bmin = $3
      if (n == 1 || $3 + 0 > bmax + 0) bmax = $3
      pip = $7
      last = $1
    }
    END {
      if (n == 0) exit
      pips = "-"
      if (pip ~ /^[0-9]*\.?[0-9]+$/ && pip + 0 > 0) pips = sprintf("%.1f", (bmax - bmin) / pip)
      print "スプレッド: 最小 " smin " / 最大 " smax
      print "値動き: 安値 " bmin " / 高値 " bmax " (値幅 " pips " pips)"
      print last
    }'
}

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file from image_file symbol n last_time
  local stats=()

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")
  from=$(($(date +%s) - 3600 * $ATST_IMAGE_REPORT_TERM))

  if [ ! -f "$monitoring_file" ]; then
    return 0
  fi

  # complete lines only (the EA may be writing the last one)
  symbol=$(tail -n 20 "$monitoring_file" | tr -d '\r' | awk -F, 'NF >= 8 {s = $8} END {print s}')

  # summary (always, with or without the images)
  mapfile -t stats < <(tr -d '\r' < "$monitoring_file" | summarize_monitoring "$from")
  if [ "${#stats[@]}" -lt 3 ]; then
    report_summaries+=("■$target_name ($symbol): 過去${ATST_IMAGE_REPORT_TERM}時間のデータがありません")
  else
    last_time="-"
    if [[ "${stats[2]}" =~ ^[0-9]+$ ]]; then
      last_time=$(date -d "@${stats[2]}" '+%m/%d %H:%M')
    fi
    report_summaries+=("■$target_name ($symbol)"$'\n'"${stats[0]}"$'\n'"${stats[1]}"$'\n'"最終データ: $last_time")
  fi

  # graphs: only when they can be uploaded (ImgBB key) and drawn (gnuplot)
  if [ "$use_graph" != 1 ]; then
    return 0
  fi

  n=${#report_images[@]}

  # spread
  image_file="$report_dir/$n-spread.png"
  awk -F, -v 'OFS=,' -v from="$from" 'NF >= 8 && $1 > from {print $1, $5}' "$monitoring_file" | "$ATST_HOME/draw_graph.sh" -t "$target_name のスプレッド" -y "pips x 10" > "$image_file"
  if [ -s "$image_file" ]; then
    report_images+=("$image_file")
    report_titles+=("$target_name のスプレッド推移")
  fi

  # price
  image_file="$report_dir/$n-price.png"
  awk -F, -v 'OFS=,' -v from="$from" 'NF >= 8 && $1 > from {print $1, $3}' "$monitoring_file" | "$ATST_HOME/draw_graph.sh" -t "$target_name の値動き" -y "$symbol" > "$image_file"
  if [ -s "$image_file" ]; then
    report_images+=("$image_file")
    report_titles+=("$target_name の値動き")
  fi
}

target_names=("$@")

if [ "$#" -le 0 ]; then
  echo "Usage: `basename $0` <MetaTrader Name1> <MetaTrader Name2> ..." 1>&2
  echo -e "\t<MetaTrader Name>: folder name of MetaTrader 4. (ex: "'"MetaTrader 4")'
  exit 1
fi

if [ "$ATST_IMAGE_REPORT_TERM" == "0" ]; then
  # disabled (before looking for gnuplot / vncsnapshot: they are not needed then)
  exit 0
fi

# Images go to a public URL (ImgBB only), so without a key the report is the text summary only.
# The desktop shows the account number and balance: sent only with ATST_IMAGE_REPORT_DESKTOP=1 (#135).
# A missing gnuplot / vncsnapshot drops those images only; the summary is still sent (P1).
use_images=0
use_graph=0
use_desktop=0
if atst_has_imgbb_key; then
  use_images=1
  if command -v gnuplot >/dev/null 2>&1; then
    use_graph=1
  else
    echo "[warn] gnuplot not found. please install gnuplot-nox package. (graphs are skipped)" 1>&2
  fi
  if [ "${ATST_IMAGE_REPORT_DESKTOP:-0}" == "1" ]; then
    if command -v vncsnapshot >/dev/null 2>&1; then
      use_desktop=1
    else
      echo "[warn] vncsnapshot not found. please install vncsnapshot package. (the desktop image is skipped)" 1>&2
    fi
  fi
fi

report_dir=$(mktemp -d "$ATST_CONFIG_DIR/report_image.XXXXXX") || exit 1
trap 'rm -rf "$report_dir"' EXIT

if [ "$use_desktop" == "1" ]; then
  desktop_image="$report_dir/desktop.jpg"
  vncsnapshot -quiet -passwd "$HOME/.vnc/passwd" -quality 30 -nocursor :1 "$desktop_image" 2> /dev/null
  if [ -s "$desktop_image" ]; then
    report_images+=("$desktop_image")
    report_titles+=("デスクトップ画像($(date +"%Y/%m/%d %H:%M:%S"))")
  fi
fi

atst_traverse_mt do_check "${target_names[@]}"

# nothing to send: none of the MTs has a terminal_monitoring.csv
if [ "${#report_summaries[@]}" -eq 0 ] && [ "${#report_images[@]}" -eq 0 ]; then
  exit 0
fi

# 4 images per push; the summaries go in the first one (sent even without images).
# Exits 1 when any push failed (atst_line_post leaves it in line_error.log).
i=0
rc=0
while :; do
  {
    echo "定期レポート(過去${ATST_IMAGE_REPORT_TERM}時間)"
    if [ "$i" -eq 0 ]; then
      [ "${#report_summaries[@]}" -gt 0 ] && printf '%s\n' "${report_summaries[@]}"
      [ "$use_images" == "1" ] || echo "画像は ImgBB の API キーが未設定のため省略 (setup_imgbb.sh で設定)"
    fi
    [ "${#report_images[@]}" -gt "$i" ] && printf '・%s\n' "${report_titles[@]:$i:4}"
  } | atst_send_to_line "${report_images[@]:$i:4}" || rc=1
  i=$((i + 4))
  [ "$i" -lt "${#report_images[@]}" ] || break
done

exit "$rc"
