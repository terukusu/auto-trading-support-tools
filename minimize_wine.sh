#!/bin/bash

if [ -z "$WINEPREFIX" ]; then
    WINEPREFIX=$HOME/.wine
fi

echo deleting needless files for wine.

rm -rf $HOME/.cache/wine/*
rm -rf $WINEPREFIX/drive_c/users/$USER/Local\ Settings/Temporary\ Internet\ Files/*
rm -rf $WINEPREFIX/drive_c/users/$USER/Application\ Data/MetaQuotes/WebInstall/*

echo done.
