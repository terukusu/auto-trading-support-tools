#!/bin/bash
#
# 毎分の監視 (再起動・約定・プロセス・監視データ・Ping・値動き・スプレッド・ハートビート) を順に 1 回ずつ
# 実行します。監視する MetaTrader の名前は ~/.atst/config の ATST_TARGETS から読みます。
# crontab には "* * * * * check_all.sh" の 1 行だけを書きます (templates/crontab.txt)。
#
# - 1 つのチェックが失敗しても残りは実行します。
# - 各チェックは ATST_CHECK_TIMEOUT 秒 (ハートビートは 60 秒) で打ち切り、打ち切ったことを LINE に通知します。
# - 前の回が終わっていなければ何もせずに終わります (積み重ならない)。止まったままなら LINE に通知します。
# - 約定のチェックは 1 回目の開始から ATST_ORDER_CHECK_INTERVAL 秒後にもう一度実行します (毎分 2 回)。
#

if [ "$#" -ne 0 ]; then
  echo "Usage: $(basename "$0")  (no arguments: the MetaTrader names are read from ATST_TARGETS in ~/.atst/config)" 1>&2
  exit 1
fi

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Only plain decimal numbers in range are used ("040" would be octal in bash arithmetic, "08" an error).
cap=40
if [ -n "${ATST_CHECK_TIMEOUT+x}" ]; then
  if [[ "$ATST_CHECK_TIMEOUT" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$ATST_CHECK_TIMEOUT" -le 300 ]; then
    cap=$ATST_CHECK_TIMEOUT
  else
    echo "ATST_CHECK_TIMEOUT is not a number of seconds from 1 to 300 ($ATST_CHECK_TIMEOUT); using 40" 1>&2
  fi
fi
interval=30
if [ -n "${ATST_ORDER_CHECK_INTERVAL+x}" ]; then
  if [[ "$ATST_ORDER_CHECK_INTERVAL" =~ ^(0|[1-9][0-9]?)$ ]] && [ "$ATST_ORDER_CHECK_INTERVAL" -le 50 ]; then
    interval=$ATST_ORDER_CHECK_INTERVAL
  else
    echo "ATST_ORDER_CHECK_INTERVAL is not a number of seconds from 0 to 50 ($ATST_ORDER_CHECK_INTERVAL); using 30" 1>&2
  fi
fi
heartbeat_cap=60

# The longest one run can take while the timeouts work: 8 check runs x (cap + 5 s to KILL), the
# heartbeat (65 s), the wait for the second check_order (50 s) and up to 10 notices of our own
# (35 s lock wait + 30 s send each), plus 60 s. A run still holding the lock after this is stuck
# outside the timeouts. A shorter threshold would fire and recover every few runs while every check
# hangs (the timeouts are reported separately), using up the monthly LINE quota.
stuck_after=$(( 8 * cap + 865 ))

lock_file="$ATST_CONFIG_DIR/check_all.lock"
started_file="$ATST_CONFIG_DIR/check_all.started"
stuck_recover="【復帰】毎分の監視 (check_all.sh) が再開しました"

# One run at a time: a run that has not finished (a slow minute or a hung check) makes the next
# minutes skip instead of piling up. Children get fd 7 closed (7>&-), so a leftover grandchild can
# never keep the lock after this runner is gone.
if ! exec 7>> "$lock_file"; then
  echo "cannot open the lock file: $lock_file" 1>&2
  exit 1
fi
if ! flock -n 7; then
  started=$(head -n 1 "$started_file" 2>/dev/null)
  # No record, a broken one or a clock that went back: undecided, say nothing.
  if [[ "$started" =~ ^[0-9]{1,12}$ ]]; then
    elapsed=$(( $(date +%s) - 10#$started ))
    if [ "$elapsed" -ge "$stuck_after" ]; then
      # Only the run that gets the lock again sends the recovery.
      atst_update_alert RUNNER_STUCK 1 \
        "【発生】毎分の監視 (check_all.sh) が、前回の実行が終わらないため ${elapsed} 秒以上止まっています" \
        "$stuck_recover"
    fi
  fi
  exit 0
fi

if ! { date +%s > "$started_file"; } 2>/dev/null; then
  echo "cannot write $started_file" 1>&2
fi
atst_update_alert RUNNER_STUCK 0 "" "$stuck_recover"

# run_check <cap> <name> [args...]
# Runs $ATST_HOME/<name>.sh, TERM after <cap> seconds and KILL 5 seconds later. timeout is not in its
# foreground mode, so the signals go to the whole process group and no grandchild is left behind.
# Returns 1 when it was cut off (124: TERM, 137: KILL), 0 otherwise: any other failure is the check's
# own business and must not stop the rest.
run_check() {
  local cap="$1" name="$2" rc
  shift 2

  timeout -k 5 "$cap" bash "$ATST_HOME/$name.sh" "$@" 7>&-
  rc=$?
  case "$rc" in
    124|137) return 1 ;;
  esac
  return 0
}

# notify_timeout <NAME> <name> <cut: 1|0> <cap>
notify_timeout() {
  atst_update_alert "RUNNER_TIMEOUT_$1" "$3" \
    "【発生】チェックが $4 秒で終わらず打ち切りました: $2.sh" \
    "【復帰】チェックが時間内に終わるようになりました: $2.sh"
}

# Milliseconds since the epoch (GNU date), for the check_order interval.
now_ms() {
  date +%s%3N
}

cut_reboot=0
cut_order=0
cut_process=0
cut_monitoring=0
cut_ping=0
cut_price=0
cut_spread=0
cut_heartbeat=0

run_check "$cap" check_reboot || cut_reboot=1

has_targets=0
if atst_has_targets; then
  has_targets=1
  atst_update_alert RUNNER_TARGETS_EMPTY 0 "" "【復帰】監視対象が設定されました"
else
  atst_update_alert RUNNER_TARGETS_EMPTY 1 \
    "【発生】監視対象が設定されていません。~/.atst/config の ATST_TARGETS に MetaTrader のフォルダ名を書いてください (MetaTrader ごとの監視と約定通知、再起動時の MetaTrader の自動起動が止まっています)" \
    "【復帰】監視対象が設定されました"
fi

if [ "$has_targets" -eq 1 ]; then
  order_start=$(now_ms)
  run_check "$cap" check_order "${ATST_TARGETS[@]}" || cut_order=1
  run_check "$cap" check_process "${ATST_TARGETS[@]}" || cut_process=1
  run_check "$cap" check_monitoring "${ATST_TARGETS[@]}" || cut_monitoring=1
  run_check "$cap" check_ping "${ATST_TARGETS[@]}" || cut_ping=1
  run_check "$cap" check_price "${ATST_TARGETS[@]}" || cut_price=1
  run_check "$cap" check_spread "${ATST_TARGETS[@]}" || cut_spread=1

  # check_order runs twice a minute about 30 seconds apart, as the old crontab did (:10 and :40),
  # so a new order is never noticed later than before. When the checks above were slow, go now.
  remain=$(( interval * 1000 - ($(now_ms) - order_start) ))
  if [ "$remain" -gt 0 ]; then
    sleep "$(( remain / 1000 )).$(printf '%03d' $(( remain % 1000 )))"
  fi
  run_check "$cap" check_order "${ATST_TARGETS[@]}" || cut_order=1
fi

# Reported after the checks, so a slow send never delays the second check_order.
notify_timeout CHECK_REBOOT check_reboot "$cut_reboot" "$cap"
if [ "$has_targets" -eq 1 ]; then
  notify_timeout CHECK_ORDER check_order "$cut_order" "$cap"
  notify_timeout CHECK_PROCESS check_process "$cut_process" "$cap"
  notify_timeout CHECK_MONITORING check_monitoring "$cut_monitoring" "$cap"
  notify_timeout CHECK_PING check_ping "$cut_ping" "$cap"
  notify_timeout CHECK_PRICE check_price "$cut_price" "$cap"
  notify_timeout CHECK_SPREAD check_spread "$cut_spread" "$cap"
fi

# Last, so the outside monitoring also notices a runner that stops before getting here.
run_check "$heartbeat_cap" heartbeat || cut_heartbeat=1
notify_timeout HEARTBEAT heartbeat "$cut_heartbeat" "$heartbeat_cap"

exit 0
