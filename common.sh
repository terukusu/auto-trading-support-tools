#!/bin/bash

ATST_HOME=$(cd "$(dirname "$BASH_SOURCE")"; pwd)
ATST_TEMPLATES_DIR="$ATST_HOME/templates"
ATST_CONFIG_DIR="$HOME/.atst"

if [ ! -e "$ATST_CONFIG_DIR" ];then
  mkdir -p "$ATST_CONFIG_DIR"
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
    cat - <(echo -en '\n\n') | sed -e 's/\r//g' | sed -e 's/\\/\\\\/g' | sed -e :loop -e 'N; $!b loop' -e 's/\n/\\n/g' | sed -e 's/\"/\\"/g' | sed -e 's/\//\\\//g'
  else
    # For linux (gnu sed)
    cat - | sed -re 's/\r//g' | sed -re 's/\\/\\\\/g' | sed -re ':loop;N;$!b loop;s/\n/\\n/g' | sed -re 's/\"/\\"/g' | sed -re 's/\//\\\//g'
  fi
}

function atst_read_file() {
  local path="$1"
  cat "$1" | sed -re 's/\r//g'
}

# 画像アップロード関数
function atst_upload_image_to_0x0() {
  local file="$1"

  if [ ! -f "$file" ]; then
    echo "Error: File not found: $file" >&2
    return 1
  fi

  # IPv4を強制的に使用してアップロード（3日間保持）
  local url=$(curl --max-time 30 --connect-timeout 10 -4 -s -F"file=@$file" -Fexpires=72 https://0x0.st 2>/dev/null)

  if [ -n "$url" ] && [[ "$url" =~ ^https?:// ]]; then
    echo "$url"
    return 0
  else
    echo "Error: Upload failed" >&2
    return 1
  fi
}

# LINE送信関数
function atst_send_to_line() {
  local msg; msg=$(cat -)
  local image_file="$1"

  local channel_access_token="$ATST_LINE_TOKEN"
  local user_id="$ATST_LINE_ID"
  local api_endpoint="https://api.line.me/v2/bot/message/push"

  # 通知本文。MT 由来の値などが含まれるため JSON へはエスケープして埋め込む (P6)。
  local text="【$(hostname -s)】$msg"

  # 画像があればアップロード。失敗時は本文に注記して画像なしで送る。
  local image_url=""
  if [ -n "$image_file" ]; then
    image_url=$(atst_upload_image_to_0x0 "$image_file")
    if [ $? -ne 0 ] || [ -z "$image_url" ]; then
      image_url=""
      text="$text (画像アップロード失敗)"
    fi
  fi

  # ペイロード生成: jq があれば全エスケープを jq に任せる。無ければ atst_escape_text を通す。
  local payload
  if command -v jq >/dev/null 2>&1; then
    if [ -n "$image_url" ]; then
      payload=$(jq -cn --arg to "$user_id" --arg t "$text" --arg u "$image_url" \
        '{to:$to, messages:[{type:"text",text:$t},{type:"image",originalContentUrl:$u,previewImageUrl:$u}]}')
    else
      payload=$(jq -cn --arg to "$user_id" --arg t "$text" \
        '{to:$to, messages:[{type:"text",text:$t}]}')
    fi
  else
    local t_e u_e url_e messages
    t_e=$(printf '%s' "$text" | atst_escape_text)
    u_e=$(printf '%s' "$user_id" | atst_escape_text)
    if [ -n "$image_url" ]; then
      url_e=$(printf '%s' "$image_url" | atst_escape_text)
      messages='[{"type":"text","text":"'"$t_e"'"},{"type":"image","originalContentUrl":"'"$url_e"'","previewImageUrl":"'"$url_e"'"}]'
    else
      messages='[{"type":"text","text":"'"$t_e"'"}]'
    fi
    payload='{"to":"'"$u_e"'","messages":'"$messages"'}'
  fi

  # メッセージ送信
  local result
  result=$(curl --max-time 30 --connect-timeout 10 -X POST "$api_endpoint" \
    -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $channel_access_token" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [ "$result" == "200" ]; then
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
#    mt_term[0]='/Users/teru/.wine/drive_c/Program Files/MetaTrader 5/terminal.exe'
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
      find "$program_folder" -maxdepth 2 -name terminal*.exe
    done
  done) | sort | while read line; do
    line=$(atst_abs_path "$line")
    mt_term="$line"
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

    echo mt_term[$i]="'$mt_term'"
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
    echo "${mt_term[$target_mt_index]}"
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
  local target_mt_home=$(atst_get_mql_folder_path "$target_name")

  if [ -z "$target_mt_home" ]; then
    return 0
  fi

  echo "$target_mt_home/Files/terminal_monitoring.csv"
}

function atst_get_mql_folder_path() {
  local target_name="$1"

  local target_index=$(atst_find_mt_index "$target_name")

  if [ -z "$target_index" ]; then
    return 0;
  fi

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

    if [ -z "$target_index" ]; then
      continue
    fi

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
