#!/bin/bash
#
# MetaTrader の名前を要する毎分以外のジョブを、~/.atst/config の ATST_TARGETS を付けて起動します。
#   run_with_targets.sh <mtctl.sh|truncate_monitoring.sh|report_image.sh> [引数...]
# 例: "@reboot run_with_targets.sh mtctl.sh start" は "mtctl.sh start <ATST_TARGETS の名前...>" を実行します。
# 名前は配列のまま渡します。
#

print_usage_exit() {
  echo "Usage: $(basename "$0") <mtctl.sh|truncate_monitoring.sh|report_image.sh> [args for the script...]" 1>&2
  echo -e "\tRuns the script with the MetaTrader names in ATST_TARGETS (~/.atst/config) appended." 1>&2
  exit 1
}

if [ "$#" -lt 1 ]; then
  print_usage_exit
fi

# A fixed list, so this never becomes a way to run an arbitrary command.
script="$1"
shift
case "$script" in
  mtctl.sh|truncate_monitoring.sh|report_image.sh) ;;
  *) print_usage_exit ;;
esac

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# The LINE notice for this is sent by check_all.sh every minute (RUNNER_TARGETS_EMPTY).
if ! atst_has_targets; then
  echo "監視対象が設定されていません。~/.atst/config の ATST_TARGETS に MetaTrader のフォルダ名を書いてください ($script は実行しませんでした)" 1>&2
  exit 1
fi

exec "$ATST_HOME/$script" "$@" "${ATST_TARGETS[@]}"
