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
  path="$1"
  cat "$1" | sed -re 's/\r//g'
}

function atst_send_to_line() {
  msg=$(cat -)
  image_file="$1"

  if [ -n "$image_file" ]; then
    image_form="-F imageFile=@$image_file"
  fi

  result=$(curl "https://notify-api.line.me/api/notify" \
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
  target_dir=$(dirname "$1")
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
  target_mt_name="$1"

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
  target_mt_name=$1

  target_mt_index=$(atst_find_mt_index "$target_mt_name")

  if [ -n "$target_mt_index" ]; then
    echo "${mt_home[$target_mt_index]}/terminal.exe"
  fi
}

function atst_find_pid() {
  target_mt_name=$1

  target_mt_path=$(atst_find_terminal "$target_mt_name")

  if [ -z "$target_mt_path" ]; then
    return 0
  fi

  target_win_path=$(winepath -w "$target_mt_path" | sed -e 's/\\/\\\\/g')

  if [ -z "$target_win_path" ]; then
    return 0
  fi

  target_pid=$(ps haxww -o pid,args | grep -v grep | grep "$target_win_path" | head -n 1 | awk '{print $1}')

  if [ -n "$target_pid" ]; then
    echo $target_pid
  fi
}

eval $(atst_gen_mt_list)
