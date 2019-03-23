#!/bin/bash

TRD_CONFIG_FILE="$(cd "$(dirname "$BASH_SOURCE")"; pwd)/config"
. $TRD_CONFIG_FILE

if [ ! -e $TRD_DATA_DIR ];then
    mkdir -p $TRD_DATA_DIR
fi

function trd_log() {
  echo "["`date "+%Y-%m-%d %H:%M:%S"`"] "$@
}

function trd_to_upper() {
  cat - | tr '[a-z]' '[A-Z]'
}

function trd_to_lower() {
  cat - | tr '[A-Z]' '[a-z]'
}

function trd_escape_text() {
  if [ "$OSTYPE" != "${OSTYPE#darwin}" ];then
    # For Mac 改行付加。末尾に最低２個の改行がないと出力が空文字になるので。
    cat - <(echo -en '\n\n') | sed -e 's/\r//g' | sed -e :loop -e 'N; $!b loop' -e 's/\n/\\n/g' | sed -e 's/\"/\\"/g' | sed -e 's/\//\\\//g'
  else
    # For linux (gnu sed)
    cat - | sed -re 's/\r//g' | sed -re ':loop;N;$!b loop;s/\n/\\n/g' | sed -re 's/\"/\\"/g' | sed -re 's/\//\\\//g'
  fi
}

function trd_read_file() {
  path="$1"
  cat "$1" | sed -re 's/\r//g'
}

function trd_send_to_line() {
  msg="`cat - | trd_escape_text`"

  for r in $TRD_LINE_RECIPIENTS; do
    curl 'https://api.line.me/v2/bot/message/push' \
      -s -o /dev/null \
      -H 'Content-Type:application/json; charset=utf-8' \
      -H 'Authorization: Bearer {'$TRD_LINE_TOKEN'}' \
      -d '{
        "to": "'"$r"'",
        "messages":[
          {
             "type":"text",
             "text":"【'`hostname -s`'】'"$msg"'"
           }
        ]
      }'
  done
}

function trd_abs_path() {
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
#    eval $(trd_gen_mt_list)
#
function trd_gen_mt_list() {
    i=0
    # Windowsの各ドライブのプログラムフォルダ内からtemrinal.exeを検索する
    cat <(find "$WINEPREFIX" -type d -name drive_* -maxdepth 1 | sort | while read drive; do
      find "$drive" -type d -name Program* -maxdepth 1 | sort | while read program_folder; do
        find "$program_folder" -name terminal.exe
      done
    done) | sort | while read line; do
      line=$(trd_abs_path "$line")
      mt_home=$(dirname "$line")
      mt_name=$(basename "$mt_home" | trd_to_upper)

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
function trd_find_mt_index() {
    target_mt_name="$1"

    if [ -z "$mt_name" ]; then
        # MT4/5情報がまだ変数としてロードされていなければこの場でロード
        # パフォーマンス向上のためにはこの関数を呼ぶ前に
        # 呼び出し元で↓を実行しておくことをお勧め
        eval $(trd_gen_mt_list)
    fi

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
function trd_find_terminal() {
    target_mt_name=$1

    if [ -z "$mt_name" ]; then
        # MT4/5情報がまだ変数としてロードされていなければこの場でロード
        # パフォーマンス向上のためにはこの関数を呼ぶ前に
        # 呼び出し元で↓を実行しておくことをお勧め
        eval $(trd_gen_mt_list)
    fi

    target_mt_index=$(trd_find_mt_index "$target_mt_name")

    if [ -n "$target_mt_index" ]; then
        echo "${mt_home[$target_mt_index]}/terminal.exe"
    fi
}
