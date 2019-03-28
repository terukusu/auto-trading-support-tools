#!/bin/bash

if [ -z "$WINEPREFIX" ]; then
    WINEPREFIX=$HOME/.wine
fi

echo deleting needless files for wine.

# find .msi and del them all!
cat <(find "$WINEPREFIX" -maxdepth 1 -type d -name drive_* | while read drive; do
  find "$drive" -type f -name *.msi
done) | sort | while read line; do
  echo $line
  rm "$line"
done

# find WibInstall folder and del them all!
cat <(find "$WINEPREFIX" -maxdepth 1 -type d -name drive_* | while read drive; do
  find "$drive" -type d -name WebInstall
done) | sort | while read line; do
  rm -rf "$line"/*
done

# find Temporary Internet Files folder and del them all!
cat <(find "$WINEPREFIX" -maxdepth 1 -type d -name drive_* | while read drive; do
  find "$drive" -type d -name "Temporary Internet Files"
done) | sort | while read line; do
  rm -rf "$line"/*
done

echo done.
