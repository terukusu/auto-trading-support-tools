#!/bin/bash

function print_usage_exit() {
  echo "Usage: cat <path/to/datafile> | $(basename $0) [-f format] [-t title]" 1>&2
  exit 0
}

while getopts pt:f:h OPT
do
  case $OPT in
    p) GP_OPT_P="-p"
    ;;
    f) FORMAT=$OPTARG
    ;;
    t) TITLE=$OPTARG
    ;;
    h) print_usage_exit
    ;;
    *) print_usage_exit
    ;;
  esac
done

shift $((OPTIND - 1))

if [ -n "$FORMAT" ]; then
    GP_SET_TERM="set terminal $FORMAT"
else
    GP_SET_TERM="set terminal pngcairo enhanced"
fi

if [ -n "$TITLE" ]; then
    GP_TITLE="ti '$TITLE'"
fi

gp_script=$(cat <<EOS
$GP_SET_TERM
set datafile separator ','
set xdata time; set timefmt '%s'
set format x '%m/%d %H:%M'
set xtic rotate by -30
plot '-' using (\$1+3600*9):2 w l $GP_TITLE
EOS
)
cat <(echo "$gp_script") - | gnuplot $GP_OPT_P
