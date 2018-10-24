#!/bin/bash

SQLITE=/usr/bin/sqlite3
DB_FILE=/home/teru/work/optionchan/data/option.db
EXEC_SQLITE="$SQLITE $DB_FILE"

# parse qseter
saveIFS=$IFS
IFS='=&'
qs=($QUERY_STRING)
IFS=$saveIFS

declare -A param
for ((i=0; i<${#qs[@]}; i+=2))
do
    param[${qs[i]}]=${qs[i+1]}
done

if [ -n "${param[ld]}" ]; then
    ld=${param[ld]}
else 
    nowd=`date +%Y-%m-%d`
    ld=`echo "SELECT min(last_trading_day) FROM option WHERE last_trading_day >= '$nowd';" | $EXEC_SQLITE`
fi

echo "Content-Type: text/plain"
echo ""

echo -e ".separator ,\nSELECT strftime('%Y-%m-%d %H:%M', CAST(strftime('%s', updated_at)/600 AS INT)*600, 'unixepoch') time, round(avg(target_price),1) as avg_atm, round(avg(iv), 2) avg_iv, round(avg(price), 1) avg_price FROM option WHERE is_atm=1 AND last_trading_day='$ld' GROUP BY CAST(strftime('%s', updated_at)/600 AS INT)*600 ORDER BY time DESC LIMIT 432;" | $EXEC_SQLITE
