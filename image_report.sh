#!/bin/bash
#
# 過去 n 時間の値動きとスプレッド、現在のデスクトップの画像を通知します。
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

function do_check() {
  local target_name="$1"
  local target_fullname="$2"

  local monitoring_file from image_file symbol


  monitoring_file=$(atst_get_monitoring_csv_path "$target_name")
  from=$(($(date +%s) - 3600 * $ATST_IMAGE_REPORT_TERM))

  if [ ! -f "$monitoring_file" ]; then
    return 0
  fi

  symbol=$(tail -n1 "$monitoring_file" | cut -d, -f 8)

  # spread
  image_file="$ATST_CONFIG_DIR/spread.png"

  cat "$monitoring_file" | awk -F, -v 'OFS=,' '{if($1 > '$from') print $1, $5}' | "$ATST_HOME/draw_graph.sh" -t "$target_name のスプレッド" -y "pips x 10" > "$image_file"

  if [ -e "$image_file" ]; then
    echo "$target_name のスプレッド推移(過去${ATST_IMAGE_REPORT_TERM}時間)" | atst_send_to_line "$image_file"
    rm "$image_file"
  fi

  # price
  image_file="$ATST_CONFIG_DIR/price.png"

  cat "$monitoring_file" | awk -F, -v 'OFS=,' '{if($1 > '$from') print $1, $3}' | "$ATST_HOME/draw_graph.sh" -t "$target_name の値動き" -y $symbol > "$image_file"

  if [ -e "$image_file" ]; then
    echo "$target_name の値動き(過去${ATST_IMAGE_REPORT_TERM}時間)" | atst_send_to_line "$image_file"
    rm "$image_file"
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

desktop_image="$ATST_CONFIG_DIR/desktop.jpg"

if [ -f "$desktop_image" ]; then
  rm "$desktop_image"
fi

vncsnapshot -quiet -passwd $HOME/.vnc/passwd -quality 30 :1 "$desktop_image" 2> /dev/null

if [ -f "$desktop_image" ]; then
  echo "デスクトップ画像($(date +"%Y/%m/%d %H:%M:%S"))" | atst_send_to_line "$desktop_image"
  rm "$desktop_image"
fi

atst_traverse_mt do_check "${target_names[@]}"
