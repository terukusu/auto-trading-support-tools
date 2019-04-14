#!/bin/bash

function print_usage_exit() {
  echo "Usage $(basename $0) <mt_names in 1 arg> <script_name> [args for script...]"
  exit 1
}

if [ $# -lt 2 ]; then
  print_usage_exit
fi

eval "target_mt=$1"
target_cmd="$2"
shift 2

$target_cmd "$@" "${target_mt[@]}" >> $HOME/hoge
