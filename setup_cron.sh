#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"

echo -n "adding task to crontab..."

cat <(crontab -l 2>/dev/null) <(cat "$TRD_TEMPLATES_DIR/crontab.txt" | sed -e "s/%%ATST_HOME%%/$(echo $TRD_ABS_PWD | sed -e 's/\//\\\//g')/g")

echo "done"
