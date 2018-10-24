#!/bin/bash

. `dirname $0`/common.sh

target=$1
if [ -z "$target" ]; then
  echo "target should be specified." 1>&2
  exit 1
fi

i=0;
while [ $i -lt $TRD_NUM_TERMINALS ]; do
  name=`eval echo '$'TRD_NAME_$i`
  path=`eval echo '$'TRD_MT4_PATH_$i`

  if [ "${target^^}" = "${name^^}" ]; then
    wine_log=$TRD_DATA_DIR/wine_log_${name,,}
    work_dir=`winepath -w "$path"`
    echo "===== START `date +'%Y-%m-%d %H:%M:%S'` =====" >> $wine_log
    DISPLAY=:1 WINEARCH=win32 WINEDEBUG=-all WINEPREFIX=/home/teru/.wine /usr/bin/wine start /d "$work_dir" /unix "$path/terminal.exe" >> $wine_log 2>&1 &
    exit 0
  fi

  i=`expr $i + 1`
done

echo "MetaTrader Terminal not found: $target" 1>&2
exit 1
