#!/bin/bash

ATST_HOME=$(cd "$(dirname "$BASH_SOURCE")"; pwd)
ATST_TEMPLATES_DIR="$ATST_HOME/templates"
ATST_CONFIG_DIR="$HOME/.atst"

if [ ! -e $ATST_CONFIG_DIR ];then
  mkdir -p $ATST_CONFIG_DIR
fi

if [ ! -e "$ATST_CONFIG_DIR/config" ]; then
  install -m 644 -D "$ATST_TEMPLATES_DIR/config" "$ATST_CONFIG_DIR/config"
fi

ATST_CONFIG_FILE="$ATST_CONFIG_DIR/config"
. $ATST_CONFIG_FILE

function atst_random_sleep() {
  local max_sleep=${1:-30}
  local random=$(( $(dd if=/dev/urandom bs=2 count=1 2> /dev/null | cksum | cut -d' ' -f1) % 32767 ))
  local sleep_time=$(($random % $max_sleep))
  sleep $sleep_time
}

function atst_log() {
  echo "["`date "+%Y-%m-%d %H:%M:%S"`"] "$@
}

function atst_to_upper() {
  cat - | tr '[a-z]' '[A-Z]'
}

function atst_to_lower() {
  cat - | tr '[A-Z]' '[a-z]'
}

function atst_escape_text() {
  if [ "$OSTYPE" != "${OSTYPE#darwin}" ];then
    # For Mac 改行付加。末尾に最低２個の改行がないと出力が空文字になるので。
    cat - <(echo -en '\n\n') | sed -e 's/\r//g' | sed -e :loop -e 'N; $!b loop' -e 's/\n/\\n/g' | sed -e 's/\"/\\"/g' | sed -e 's/\//\\\//g'
  else
    # For linux (gnu sed)
    cat - | sed -re 's/\r//g' | sed -re ':loop;N;$!b loop;s/\n/\\n/g' | sed -re 's/\"/\\"/g' | sed -re 's/\//\\\//g'
  fi
}

function atst_read_file() {
  local path="$1"
  cat "$1" | sed -re 's/\r//g'
}

function atst_send_to_line() {
  local msg=$(cat -)
  local image_file="$1"

  if [ -n "$image_file" ]; then
    local image_form="-F imageFile=@$image_file"
  fi

  local result=$(curl "https://notify-api.line.me/api/notify" \
    -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $ATST_LINE_TOKEN" \
    -F "message=【$(hostname -s)】$msg" $image_form)

  if [ -n "$result" -a "$result" == "200" ]; then
    return 0
  else
    return 1
  fi
}

function atst_abs_path() {
  local target_dir=$(dirname "$1")
  echo $(cd "$target_dir" && pwd)/$(basename "$1")
}

# scan wine drive and find terminal.exe. and output lines like below.
#
#    mt_home[0]='/Users/teru/.wine/drive_c/Program Files/MetaTrader 4'
#    mt_name[0]='METATRADER 4'
#    mt_type[0]='MT4'
#    mt_home[1]....
#    mt_name[1]....
#    mt_type[1]....
#
# Evaluating like this, you can use them as valiable.
#    eval $(atst_gen_mt_list)
#
function atst_gen_mt_list() {
  if [ ! -d "$WINEPREFIX" ]; then
    return 0
  fi

  i=0
  # Windowsの各ドライブのプログラムフォルダ内からtemrinal.exeを検索する
  cat <(find "$WINEPREFIX" -maxdepth 1 -type d -name drive_* | sort | while read drive; do
    find "$drive" -maxdepth 1 -type d -name Program* -maxdepth 1 | sort | while read program_folder; do
      find "$program_folder" -maxdepth 2 -name terminal.exe
    done
  done) | sort | while read line; do
    line=$(atst_abs_path "$line")
    mt_home=$(dirname "$line")
    mt_name=$(basename "$mt_home" | atst_to_upper)

    if [ -d "$mt_home/MQL4" ]; then
      mt_type=MT4
    elif [ -d "$mt_home/MQL5" ]; then
      mt_type=MT5
    else
      echo "cannot determine MT4/MT5. bcause it don't have MQL4/ML5 folder: '$mt_home'" 1>&2
      continue
    fi

    echo mt_home[$i]="'$mt_home'"
    echo mt_name[$i]="'$mt_name'"
    echo mt_type[$i]="'$mt_type'"

    i=`expr $i + 1`
  done
}

# return the index of MetaTrader which folder has specified prefix
# return empty when it's not found.
#
function atst_find_mt_index() {
  local target_mt_name="$1"

  i=0
  while [ $i -lt ${#mt_home[@]} ]; do
    match="$(echo ${mt_name[$i]} | grep -ioE "^$target_mt_name")"
    if [ -n "$match" ]; then
      echo $i
      break
    fi
    let i++
  done
}

# return absolute path of the terminal.exe
# Returns the path of the termina.exe with a case-insensitive
# prefix match between argument 1 and the folder name.
#
function atst_find_terminal() {
  local target_mt_name=$1

  local target_mt_index=$(atst_find_mt_index "$target_mt_name")

  if [ -n "$target_mt_index" ]; then
    echo "${mt_home[$target_mt_index]}/terminal.exe"
  fi
}

function atst_find_pid() {
  local target_mt_name=$1

  local target_mt_path=$(atst_find_terminal "$target_mt_name")

  if [ -z "$target_mt_path" ]; then
    return 0
  fi

  local target_win_path=$(winepath -w "$target_mt_path" | sed -e 's/\\/\\\\/g')

  if [ -z "$target_win_path" ]; then
    return 0
  fi

  local target_pid=$(ps haxww -o pid,args | grep -v grep | grep "$target_win_path" | head -n 1 | awk '{print $1}')

  if [ -n "$target_pid" ]; then
    echo $target_pid
  fi
}

function atst_get_monitoring_csv_path() {
  local target_name="$1"

  echo "$(atst_get_mql_folder_path "$target_name")/Files/terminal_monitoring.csv"
}

function atst_get_mql_folder_path() {
  local target_name="$1"

  local target_index=$(atst_find_mt_index "$target_name")
  local target_path=${mt_home[$target_index]}
  local target_type=${mt_type[$target_index]}
  local target_fullname=${mt_name[$target_index]}

  local target_mql_folder

  if [ "$target_type" == "MT4" ]; then
    target_mql_folder="MQL4"
  else
    target_mql_folder="MQL5"
  fi

  echo "$target_path/$target_mql_folder"
}

function atst_traverse_mt() {
  local callback_function="$1"
  shift

  local target_names=("$@")

  local target_name target_index target_path target_type target_fullname

  for target_name in "${target_names[@]}"; do
    target_index=$(atst_find_mt_index "$target_name")
    target_path=${mt_home[$target_index]}
    target_type=${mt_type[$target_index]}
    target_fullname=${mt_name[$target_index]}

    "$callback_function" "$target_name" "$target_fullname" "$target_path" "$target_type"
  done
}

function atst_set_alert_status() {
  local key=$1
  local value=$2

  if [ -z "$key" ]; then
    echo "alert status key should not be empty" 1>&2
    return 1
  fi

  if [ -e "$ATST_ALERT_STATUS_FILE" ] && [ -n "$(cat "$ATST_ALERT_STATUS_FILE" | grep -o "${key}," )" ]; then
    sed -i -e "s/$key,.*/$key,$value,$(date +%s)/" "$ATST_ALERT_STATUS_FILE"
  else
    echo $key,$value,$(date +%s) >> "$ATST_ALERT_STATUS_FILE"
  fi
}

function atst_get_alert_status() {
  local key="$1"
  local default="$2"

  if [ -e "$ATST_ALERT_STATUS_FILE" ]; then
    echo "$(cat "$ATST_ALERT_STATUS_FILE" | grep -oE "${key},.*" | cut -d',' -f 2)"
  else
    echo "$default"
  fi
}

function atst_get_alert_status_time() {
  local key="$1"
  local default="$2"

  if [ -e "$ATST_ALERT_STATUS_FILE" ]; then
    echo "$(cat "$ATST_ALERT_STATUS_FILE" | grep -oE "${key},.*" | cut -d',' -f 3)"
  else
    echo "$default"
  fi
}

eval $(atst_gen_mt_list)
