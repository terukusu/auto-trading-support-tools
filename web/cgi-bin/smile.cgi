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

for ((i=0; i<${#qs[@]}; i+=2))
do
    param[${qs[i]}]=${qs[i+1]}
done

lu=`echo "SELECT max(updated_at) FROM future_price_info;" | $EXEC_SQLITE`

if [ -n "${param[ld]}" ]; then
    ld1=${param[ld]}
else
    nowd=`date +%Y-%m-%d`
    tmp=(`echo "SELECT distinct(last_trading_day) FROM option WHERE updated_at='$lu' ORDER BY last_trading_day LIMIT 3;" | $EXEC_SQLITE | xargs`)
    ld1=${tmp[0]}
    ld2=${tmp[1]}
    ld3=${tmp[2]}
fi

atm=`echo "SELECT target_price FROM option WHERE type=1 AND is_atm=1 AND updated_at='$lu' AND last_trading_day='$ld1' LIMIT 1;" | $EXEC_SQLITE`
min_price=`expr $atm - 5000`
IDX="INDEXED BY ix_option_updated_at"

echo "Content-Type: text/plain"
echo ""

echo $lu,$atm
echo -e ".separator ,\nSELECT o1.target_price, o1.iv, o1.price_time, o2.iv,  o2.price_time, o3.iv, o3.price_time, o4.iv, o4.price_time FROM (SELECT target_price, iv, price_time FROM option $IDX WHERE target_price >= $min_price AND type=1 AND last_trading_day='$ld1' AND updated_at='$lu') o1, (SELECT target_price, iv, price_time FROM option $IDX WHERE target_price >= $min_price AND type=2 AND last_trading_day='$ld1' AND updated_at='$lu') o2, (SELECT target_price, iv, price_time FROM option $IDX WHERE target_price >= $min_price AND type=1 AND last_trading_day='$ld2' AND updated_at='$lu') o3, (SELECT target_price, iv, price_time FROM option $IDX WHERE target_price >= $min_price AND type=2 AND last_trading_day='$ld2' AND updated_at='$lu') o4 WHERE o1.target_price = o2.target_price AND o1.target_price = o3.target_price AND o1.target_price = o4.target_price ORDER BY o1.target_price ASC;" | $EXEC_SQLITE
