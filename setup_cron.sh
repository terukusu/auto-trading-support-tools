#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"


crontab_old=$(crontab -l 2>/dev/null)

is_overwrite=1

if [ -n "$crontab_old" ]; then
  echo "Your crontab is not empty. Overwrite it? (Y/n)('n' means append.)"
  read line

  if [ "${line,,}" == "n" ]; then
    is_overwrite=0
  fi
fi

echo "adding task to crontab..."

if [ "$is_overwrite" == "1" ]; then
  cat "$ATST_TEMPLATES_DIR/crontab.txt" | sed -e "s/%%ATST_HOME%%/$(echo $ATST_HOME | sed -e 's/\//\\\//g')/g" | crontab
else
  cat <(crontab -l 2>/dev/null) <(cat "$ATST_TEMPLATES_DIR/crontab.txt" | sed -e "s/%%ATST_HOME%%/$(echo $ATST_HOME | sed -e 's/\//\\\//g')/g") | crontab
fi

echo "done"
