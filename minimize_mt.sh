#!/bin/bash

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

num_mt=${#mt_home[@]}

echo $num_mt MetaTraders are found.

i=0
while [ $i -lt $num_mt ]; do
  home="${mt_home[$i]}"
  echo "processing: [$(($i + 1))/$num_mt] type=${mt_type[$i]}  path='$home'"
  echo "delete needless files.."

  # the data folder (AppData side) holds history and mail when it differs from the install folder
  for d in "$home" "${mt_data[$i]}"; do
    [ -d "$d" ] || continue
    find "$d" -type d -name 'mail*' -exec sh -c 'rm -rf -- "$1"/*' _ {} \;
    find "$d" -name '*.hst' -exec rm {} \;
    find "$d" -name 'news.dat' -exec rm {} \;
  done

  echo "done"

  let i++
done

echo deleting needless update data.

# Every user in the prefix: cron does not always set $USER. Newer Wine has AppData/Roaming.
clwdir=(
  "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/MetaQuotes
  "$WINEPREFIX"/drive_c/users/*/"Application Data"/MetaQuotes
  "$WINEPREFIX/drive_c/ProgramData/MetaQuotes"
  "$WINEPREFIX/drive_c/Documents and Settings/All Users/Application Data/MetaQuotes"
)

for d in "${clwdir[@]}"; do
  find "$d" -type f -name 'mt?clw*.png' 2>/dev/null
done | while read png; do
  type=$(file -Z -b "$png" | grep -ioE "PE.*executable|data")
  if [ -n "$type" ]; then
    rm "$png";
  fi
done

echo "done"

exit 0
