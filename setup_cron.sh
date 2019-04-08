#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"

echo "adding task to crontab..."

cat <(crontab -l 2>/dev/null) <(cat "$ATST_TEMPLATES_DIR/crontab.txt" | sed -e "s/%%ATST_HOME%%/$(echo $ATST_HOME | sed -e 's/\//\\\//g')/g") | crontab

echo "done"
