#!/bin/bash
#
# 毎分の監視 (再起動・約定・プロセス・監視データ・ティック・取引可否・Ping・値動き・スプレッド・ハートビート) を順に 1 回ずつ
# 実行します。監視する MetaTrader の名前は ~/.atst/config の ATST_TARGETS から読みます。
# crontab には "* * * * * check_all.sh" の 1 行だけを書きます (templates/crontab.txt)。
#
# - 1 つのチェックが失敗しても残りは実行します。
# - 各チェックは ATST_CHECK_TIMEOUT 秒 (ハートビートは 60 秒) で打ち切り、打ち切ったことを LINE に通知します。
# - 前の回が終わっていなければ何もせずに終わります (積み重ならない)。止まったままなら LINE に通知します。
# - 約定のチェックは 1 回目の開始から ATST_ORDER_CHECK_INTERVAL 秒後にもう一度実行します (毎分 2 回)。
# - その回の通知 (発生・復帰・再起動の検出・打ち切り) は 1 通にまとめて LINE に送ります
#   (1 回目のチェック群の後に 1 回、後から出た打ち切りの通知は回の最後にもう 1 回)。約定通知は従来どおり即時です。
# - 自分と各チェックの stderr は ~/.atst/log/check_all.log に追記します (回の先頭に START 行。書けなければ従来どおり)。
#

if [ "$#" -ne 0 ]; then
  echo "Usage: $(basename "$0")  (no arguments: the MetaTrader names are read from ATST_TARGETS in ~/.atst/config)" 1>&2
  exit 1
fi

# The stderr of this run and of every check goes to ~/.atst/log/check_all.log (#144): cron throws it
# away (MAILTO=""). Done before common.sh so its [warn] on ~/.atst/config is kept. Any failure here
# leaves stderr as it was and changes nothing else: the checks must run anyway. "command exec" so a
# failed redirection is not fatal even in POSIX mode. No 2>/dev/null on the exec: it would undo it.
if [ -n "$HOME" ]; then
  run_log_dir="$HOME/.atst/log"
  run_log="$run_log_dir/check_all.log"
  if { [ -d "$run_log_dir" ] || ( umask 077; mkdir -p -- "$run_log_dir" ) 2>/dev/null; } \
    && { [ -e "$run_log" ] || ( umask 077; : > "$run_log" ) 2>/dev/null; } \
    && command exec 2>> "$run_log"; then
    echo "===== START $(date '+%Y-%m-%d %H:%M:%S') pid=$$ =====" 1>&2
  fi
fi

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Only atst_spool_begin below sets the spool of this run. A value inherited from the calling shell must
# not put our notices (RUNNER_STUCK when the lock is busy) into another run's spool.
unset ATST_NOTIFY_SPOOL

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

# The longest one run can take while the timeouts work:
# - 10 check runs x (cap + 5 s to KILL): 10 * cap + 50
# - the heartbeat (60 + 5 s): 65
# - the wait for the second check_order (ATST_ORDER_CHECK_INTERVAL, at most 50 s): 50
# - up to 10 notices of our own sent at once when they cannot be spooled (35 s lock wait + 30 s send
#   each): 650
# - the two flushes of the spool: the first (10 s for all its key locks + 2 pushes x 30 s) and the
#   last (10 s + 1 push x 30 s): 110
# - a margin: 50 (60 before #137, 55 before #158; the total is kept at 975)
# 50 + 65 + 50 + 650 + 110 + 50 = 975. The alert_status lock (flock -w 10 in atst_set_alert_status)
# is held for one awk only and is not counted (as before).
# A run still holding the lock after this is stuck outside the timeouts. A shorter threshold would
# fire and recover every few runs while every check hangs (the timeouts are reported separately),
# using up the monthly LINE quota.
stuck_after=$(( 10 * cap + 975 ))

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
  skip_ago='?'
  # No record, a broken one or a clock that went back: undecided, say nothing.
  if [[ "$started" =~ ^[0-9]{1,12}$ ]]; then
    elapsed=$(( $(date +%s) - 10#$started ))
    skip_ago=$elapsed
    if [ "$elapsed" -ge "$stuck_after" ]; then
      # Only the run that gets the lock again sends the recovery.
      atst_update_alert RUNNER_STUCK 1 \
        "【発生】毎分の監視 (check_all.sh) が、前回の実行が終わらないため ${elapsed} 秒以上止まっています" \
        "$stuck_recover"
    fi
  fi
  echo "another run holds the lock (started $skip_ago s ago); skipped" 1>&2
  exit 0
fi

if ! { date +%s > "$started_file"; } 2>/dev/null; then
  echo "cannot write $started_file" 1>&2
fi
# The notices of this run go to the spool and are sent together (atst_spool_flush below). When the
# spool cannot be made, they are sent one by one as before.
atst_spool_begin
atst_update_alert RUNNER_STUCK 0 "" "$stuck_recover"

# run_check <cap> <name> [args...]
# Runs $ATST_HOME/<name>.sh, TERM after <cap> seconds and KILL 5 seconds later. timeout is not in its
# foreground mode, so the signals go to the whole process group and no grandchild is left behind.
# Returns 1 when it was cut off (124: TERM, 137: KILL), 0 otherwise: any other failure is the check's
# own business and must not stop the rest. A non-zero exit is noted in one stderr line (the log).
run_check() {
  local cap="$1" name="$2" rc
  shift 2

  timeout -k 5 "$cap" bash "$ATST_HOME/$name.sh" "$@" 7>&-
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$name.sh: exit $rc" 1>&2
  fi
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
cut_tick=0
cut_trade_ready=0
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
  run_check "$cap" check_tick "${ATST_TARGETS[@]}" || cut_tick=1
  run_check "$cap" check_trade_ready "${ATST_TARGETS[@]}" || cut_trade_ready=1
  run_check "$cap" check_ping "${ATST_TARGETS[@]}" || cut_ping=1
  run_check "$cap" check_price "${ATST_TARGETS[@]}" || cut_price=1
  run_check "$cap" check_spread "${ATST_TARGETS[@]}" || cut_spread=1
fi

# Added to the spool (no send here), so reporting them before the second check_order delays nothing.
# CHECK_ORDER is reported after its second run, which its cut-off flag also covers.
notify_timeout CHECK_REBOOT check_reboot "$cut_reboot" "$cap"
if [ "$has_targets" -eq 1 ]; then
  notify_timeout CHECK_PROCESS check_process "$cut_process" "$cap"
  notify_timeout CHECK_MONITORING check_monitoring "$cut_monitoring" "$cap"
  notify_timeout CHECK_TICK check_tick "$cut_tick" "$cap"
  notify_timeout CHECK_TRADE_READY check_trade_ready "$cut_trade_ready" "$cap"
  notify_timeout CHECK_PING check_ping "$cut_ping" "$cap"
  notify_timeout CHECK_PRICE check_price "$cut_price" "$cap"
  notify_timeout CHECK_SPREAD check_spread "$cut_spread" "$cap"
fi

# Every notice so far in one push, before the wait for the second check_order, so a usual run's
# notices are not delayed by that wait (and the time this send takes comes out of the wait).
atst_spool_flush 2

if [ "$has_targets" -eq 1 ]; then
  # check_order runs twice a minute about 30 seconds apart, as the old crontab did (:10 and :40),
  # so a new order is never noticed later than before. When the checks above were slow, go now.
  remain=$(( interval * 1000 - ($(now_ms) - order_start) ))
  if [ "$remain" -gt 0 ]; then
    sleep "$(( remain / 1000 )).$(printf '%03d' $(( remain % 1000 )))"
  fi
  run_check "$cap" check_order "${ATST_TARGETS[@]}" || cut_order=1
  notify_timeout CHECK_ORDER check_order "$cut_order" "$cap"
fi

# Last, so the outside monitoring also notices a runner that stops before getting here.
run_check "$heartbeat_cap" heartbeat || cut_heartbeat=1
notify_timeout HEARTBEAT heartbeat "$cut_heartbeat" "$heartbeat_cap"

# What came after the first flush (a cut-off second check_order or heartbeat); empty in a usual run.
atst_spool_flush 1
atst_spool_end

exit 0
