#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

eval $(trd_gen_mt_list)

num_mt=${#mt_home[@]}

echo $num_mt MetaTraders are found.

i=0
while [ $i -lt $num_mt ]; do
    mt_home="${mt_home[$i]}"
    echo "processing: [$i/$num_mt] type=${mt_type[$i]}  path='$mt_home'"
    echo "delete needless files.."

    mails=$(ls "$mt_home/history/mailbox")
    
    if [ -n "$mails" ]; then
        rm "$mt_home/history/mailbox/"*
    fi
    
    find "$mt_home" -name '*.hst' -exec rm {} \;
    find "$mt_home" -name 'news.dat' -exec rm {} \;
    
    echo done

    let i++
done

exit 0
