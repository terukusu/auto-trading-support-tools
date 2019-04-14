#!/bin/bash

function print_usage_exit() {
  echo "Usage $(basename $0) <script_name> <mt_names in 1 arg> [args for script...]"
  exit 1
}

if [ $# -lt 2 ]; then
  print_usage_exit
fi

target_cmd="$1"
eval "target_mt=$2"
shift 2

$target_cmd "$@" "${target_mt[@]}" >> $HOME/hoge
