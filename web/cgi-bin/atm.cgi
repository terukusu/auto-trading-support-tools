#!/bin/bash

if [ -z "$SQLITE" ]; then
  SQLITE=/usr/bin/sqlite3
fi

if [ -z "$DB_FILE" ]; then
  DB_FILE=/home/teru/work/optionchan/data/option.db
fi

EXEC_SQLITE="$SQLITE $DB_FILE"

# parse qseter
saveIFS=$IFS
IFS='=&'
qs=($QUERY_STRING)
IFS=$saveIFS

if [ "$(uname)" != 'Darwin' ]; then
  declare -A param
fi

for ((i=0; i<${#qs[@]}; i+=2)); do
  param[${qs[i]}]=${qs[i+1]}
done

lu=`echo "SELECT max(updated_at) FROM future_price_info;" | $EXEC_SQLITE`

if [ -n "${param[ld]}" ]; then
    ld=${param[ld]}
else
    # nowd=`date +%Y-%m-%d`
    ld=`echo "SELECT min(last_trading_day) FROM option WHERE updated_at='$lu';" | $EXEC_SQLITE`
fi

echo "Content-Type: text/plain"
echo ""

echo "$lu"
echo -e ".separator ,\nSELECT CAST(updated_at/600 AS INT)*600 time, round(avg(target_price),1) as avg_atm, round(avg(iv), 2) avg_iv, round(avg(price), 1) avg_price FROM option WHERE is_atm=1 AND last_trading_day='$ld' AND updated_at > strftime('%s', datetime('now', 'localtime'))-(3600*24*7) GROUP BY CAST(updated_at/600 AS INT)*600 ORDER BY time DESC LIMIT 432;" | $EXEC_SQLITE
