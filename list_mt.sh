#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

eval $(trd_gen_mt_list)

num_mt=${#mt_home[@]}

echo $num_mt MetaTrader found.

i=0
while [ "$i" -lt ${#mt_home[@]} ]; do
  echo [$(($i + 1))/$num_mt]: name=${mt_name[$i]}, home=${mt_home[$i]}
  let i++
done
