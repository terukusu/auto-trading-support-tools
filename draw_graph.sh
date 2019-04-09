#!/bin/bash

function print_usage_exit() {
  echo "Usage: cat <path/to/datafile> | $(basename $0) [-f format] [-t title]" 1>&2
  exit 0
}

if [ -z "$(which gnuplot)" ]; then
  echo gnuplot not found. please install gnuplot-nox package. 1>&2
  exit 1
fi

while getopts pt:f:hx:y: OPT
do
  case $OPT in
    p) GP_OPT_P="-p"
    ;;
    f) FORMAT=$OPTARG
    ;;
    t) TITLE=$OPTARG
    ;;
    x) X_LABEL=$OPTARG
    ;;
    y) Y_LABEL=$OPTARG
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

if [ -n "$X_LABEL" ]; then
    GP_X_LABEL="set xlabel '$X_LABEL'"
fi

if [ -n "$Y_LABEL" ]; then
    GP_Y_LABEL="set ylabel '$Y_LABEL'"
fi

gp_script=$(cat <<EOS
$GP_SET_TERM
$GP_X_LABEL
$GP_Y_LABEL
set datafile separator ','
set xdata time; set timefmt '%s'
set format x '%m/%d %H:%M'
set xtic rotate by -30
plot '-' using (\$1+3600*9):2 w l $GP_TITLE
EOS
)
cat <(echo "$gp_script") - | gnuplot $GP_OPT_P
