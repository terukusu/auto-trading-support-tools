#!/bin/bash
#
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"


for target_name in "${mt_name[@]}"; do
  mql_folder_path=$(atst_get_mql_folder_path "$target_name")

  echo Installing TerminalMonitoring EA to $mql_folder_path
  if [ -n "$(echo $mql_folder_path | grep -o MQL4)" ]; then
    install -m 644 -D $ATST_HOME/MQL4/Experts/TerminalMonitoring.mq4 "$mql_folder_path/Experts"
    install -m 644 -D $ATST_HOME/MQL4/Experts/TerminalMonitoring.ex4 "$mql_folder_path/Experts"
  else
    install -m 644 -D $ATST_HOME/MQL5/Experts/Advisors/TerminalMonitoring.mq5 "$mql_folder_path/Experts/Advisors"
    install -m 644 -D $ATST_HOME/MQL5/Experts/Advisors/TerminalMonitoring.ex5 "$mql_folder_path/Experts/Advisors"
  fi
  echo "done"
done
