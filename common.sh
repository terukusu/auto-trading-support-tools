#!/bin/bash

TRD_CONFIG_FILE=$(cd $(dirname $BASH_SOURCE); pwd)/config
. $TRD_CONFIG_FILE

if [ ! -e $TRD_DATA_DIR ];then
    mkdir -p $TRD_DATA_DIR
fi

function trd_log() {
  echo "["`date "+%Y-%m-%d %H:%M:%S"`"] "$@
}

function trd_escape_text() {
  sed -re 's/\r//g' | sed -re ':loop;N;$!b loop;s/\n/\\n/g' | sed -re 's/\"/\\"/g' | sed -re 's/\//\\\//g'
}

function trd_read_file() {
  path="$1"
  cat "$1" | sed -re 's/\r//g'
}

function trd_send_to_line() {
  msg="`cat - | trd_escape_text`"

  for r in $TRD_RECIPIENTS; do
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
