#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"


for target_name in "$mt_name[@]"; do
  mql_folder_path=$(atst_get_mql_folder_path "$target_name")

  echo installing TerminalMonitoring EA to $mql_folder_path

  install -m 644 -D $ATST_HOME/MQL4/Experts/TerminalMonitoring.mq4 "$mql_folder_path/Experts/"
  install -m 644 -D $ATST_HOME/MQL4/Experts/TerminalMonitoring.ex4 "$mql_folder_path/Experts/"
done
