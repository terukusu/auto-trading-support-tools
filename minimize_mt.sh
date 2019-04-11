#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"

num_mt=${#mt_home[@]}

echo $num_mt MetaTraders are found.

i=0
while [ $i -lt $num_mt ]; do
  mt_home="${mt_home[$i]}"
  echo "processing: [$(($i + 1))/$num_mt] type=${mt_type[$i]}  path='$mt_home'"
  echo "delete needless files.."

  find "$mt_home" -type d -name mail* -exec bash -c 'cd "{}"; rm -rf *' \;
  find "$mt_home" -name '*.hst' -exec rm {} \;
  find "$mt_home" -name 'news.dat' -exec rm {} \;

  echo done

  let i++
done

exit 0
