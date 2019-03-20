#!/bin/bash

MT4_TERMINAL="`find ~/.wine/drive_c -type f -name terminal.exe | head -n 1`"
if [ -z "$MT4_TERMINAL" ];then
    echo "MT4 not found. exitting..." 1>&2
    exit 1
fi

echo MT4 found at "'$MT4_TERMINAL'"

MT4_HOME=$(dirname "$MT4_TERMINAL")
mails=$(ls "$MT4_HOME/history/mailbox")

echo "delete needless files.."

if [ -n "$mails" ]; then
    rm "$MT4_HOME/history/mailbox/"*
fi

find "$MT4_HOME" -name '*.hst' -exec rm {} \;
find "$MT4_HOME" -name 'news.dat' -exec rm {} \;

echo done

exit 0