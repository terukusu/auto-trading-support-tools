#!/bin/bash
#
# 過去 n 時間の値動きとスプレッド、現在のデスクトップの画像を通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

# Images are collected and sent together: LINE counts one push as one message however many images it
# carries (free plan: 200 a month), and a push holds up to 4 images with the text.
report_dir=""
report_images=()
report_titles=()

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file from image_file symbol n

  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")
  from=$(($(date +%s) - 3600 * $ATST_IMAGE_REPORT_TERM))

  if [ ! -f "$monitoring_file" ]; then
    return 0
  fi

  # complete lines only (the EA may be writing the last one)
  symbol=$(tail -n 20 "$monitoring_file" | tr -d '\r' | awk -F, 'NF >= 8 {s = $8} END {print s}')
  n=${#report_images[@]}

  # spread
  image_file="$report_dir/$n-spread.png"
  awk -F, -v 'OFS=,' 'NF >= 8 {if($1 > '$from') print $1, $5}' "$monitoring_file" | "$ATST_HOME/draw_graph.sh" -t "$target_name のスプレッド" -y "pips x 10" > "$image_file"
  if [ -s "$image_file" ]; then
    report_images+=("$image_file")
    report_titles+=("$target_name のスプレッド推移")
  fi

  # price
  image_file="$report_dir/$n-price.png"
  awk -F, -v 'OFS=,' 'NF >= 8 {if($1 > '$from') print $1, $3}' "$monitoring_file" | "$ATST_HOME/draw_graph.sh" -t "$target_name の値動き" -y "$symbol" > "$image_file"
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

if [ -z "$(which gnuplot)" ]; then
  echo gnuplot not found. please install gnuplot-nox package. 1>&2
  exit 1
fi

if [ -z "$(which vncsnapshot)" ]; then
  echo vncsnapshot not found. please install vncsnapshot package. 1>&2
  exit 1
fi

if [ "$ATST_IMAGE_REPORT_TERM" == "0" ]; then
  # disaled
  exit 0
fi

report_dir=$(mktemp -d "$ATST_CONFIG_DIR/report_image.XXXXXX") || exit 1
trap 'rm -rf "$report_dir"' EXIT

desktop_image="$report_dir/desktop.jpg"
vncsnapshot -quiet -passwd $HOME/.vnc/passwd -quality 30 -nocursor :1 "$desktop_image" 2> /dev/null
if [ -s "$desktop_image" ]; then
  report_images+=("$desktop_image")
  report_titles+=("デスクトップ画像($(date +"%Y/%m/%d %H:%M:%S"))")
fi

atst_traverse_mt do_check "${target_names[@]}"

# 4 images per push
i=0
while [ "$i" -lt "${#report_images[@]}" ]; do
  {
    echo "定期レポート(過去${ATST_IMAGE_REPORT_TERM}時間)"
    printf '・%s\n' "${report_titles[@]:$i:4}"
  } | atst_send_to_line "${report_images[@]:$i:4}"
  i=$((i + 4))
done
