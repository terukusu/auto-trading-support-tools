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

echo deleting needless update data.

clwdir=(
  "$WINEPREFIX/drive_c/users/$USER/Application Data/MetaQuotes"
  "$WINEPREFIX/drive_c/ProgramData/MetaQuotes"
  "$WINEPREFIX/drive_c/Documents and Settings/All Users/Application Data/MetaQuotes"
)

for d in "${clwdir[@]}"; do
  find "$d" -type f -name mt?clw*.png 2>/dev/null
done | while read png; do
  type=$(file -Z -b "$png" | grep -ioE "PE.*executable|data")
  if [ -n "$type" ]; then
    rm "$png";
  fi
done

echo done

exit 0
