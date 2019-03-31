#!/bin/bash

DIR_VNC="$HOME/.vnc"

pid_files=$(ls -w1 $DIR_VNC/*.pid 2>/dev/null)

result=$(for h in $pid_files; do
    pid=$(cat $h)
    display=$(echo $h | grep -oE ':[0-9]+')
    is_running=$(ps h -o comm -p $pid)

    if [ -n "$is_running" ]; then
        echo VNC Server is running at DISPLAY $display, pid=$pid
    fi
done)

if [ -n "$result" ]; then
    echo "$result" | while read line; do
        echo $line
    done
else
    echo "VNC Server is not running."
    exit 0
fi
