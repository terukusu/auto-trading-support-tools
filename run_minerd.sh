#!/bin/bash

. `dirname $0`/common.sh

"$TRD_DIR/minerd" -t 1 -a yescrypt -o stratum+tcp://lycheebit.com:6234 -u ZkVimmttoL2EhcDaF18pcMduCCUcg2W1LW  -p "c=ZNY" >> "$TRD_DATA_DIR/minerd.log" 2>&1 &
