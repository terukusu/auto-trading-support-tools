#!/bin/bash
#
# 外形監視のハートビート (Healthchecks.io などの ping URL)。check_all.sh が毎分の最後に実行します。
# URL は ~/.atst/.heartbeat_url (setup_heartbeat.sh で設定)、無ければ config の ATST_HEARTBEAT_URL。
# 設定されていなければ何もしません。
#
# - 監視自体の健全性に関わる異常が発生中なら <URL>/fail に POST、無ければ <URL> に ping (GET)。
#   1 回の実行で送るのはどちらか 1 回だけです。
#   ping が途絶える = cron / VPS / ネットワークの停止、/fail が届く = 監視が異常を検知中 (LINE が死んでいても届く)。
# - 対象: ~/.atst/alert_status で値が 1 のキーのうち PROCESS_ / TARGET_ / MONITORING_ / TICK_ / TRADE_ / RUNNER_
#   / LINE_ で始まるもの (LINE_QUOTA は check_daily.sh が書く)。ただし RUNNER_TIMEOUT_HEARTBEAT は除く (打ち切られた
#   相手は外部サービス自身で、ping の途絶として既に見えている)。加えて line_error.log の直近 60 分に LINE の
#   送信失敗が ATST_HEARTBEAT_LINE_FAIL_COUNT 件 (既定 3) 続いていれば LINE_SEND_FAILED。
# - 対象外: PRICE_ / SPREAD_ / PING_ (相場・回線品質は LINE の通知で足りる)、IMAGE_REPORT_DEFAULT_CHANGED など
#   上に挙げていないキー (許可リストで判定する)。
# - /fail の本文は発生中のキー名を空白で区切った 1 行だけ (建玉・口座・通知の文面・ホスト名は入れない)。
# - URL と本文は curl の設定ファイル (-K、プロセス置換) で渡し、argv に載せない (ps で見えないように。
#   URL を知っていれば誰でも生存を報告できる。P5, #81)。curl のエラー文 (ホスト名を含む) は捨て、
#   stderr には URL を含まない 1 行だけを出す (check_all.sh の stderr は ~/.atst/log に残る)。
# - alert_status も line_error.log も読むだけで、何も書きません (ロックも取らない。alert_status は
#   一時ファイル + mv で置き換えられるので、旧版か新版のどちらかを丸ごと読む)。
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

url=${ATST_HEARTBEAT_URL:-}
if [ -z "$url" ]; then
  exit 0
fi

# A space, " or \ would break the quoting of the -K line and could add a line of its own.
case $url in
  *[[:space:]\"\\]*)
    echo "heartbeat: ATST_HEARTBEAT_URL is invalid" 1>&2
    exit 1
    ;;
esac
while [ "${url%/}" != "$url" ]; do
  url=${url%/}
done

# Keys of alert_status set to 1, in file order, from the allow list only.
keys=""
if [ -n "${ATST_ALERT_STATUS_FILE:-}" ]; then
  keys=$(awk -F, '
    $2 == "1" && $1 ~ /^(PROCESS_|TARGET_|MONITORING_|TICK_|TRADE_|RUNNER_|LINE_)/ && $1 != "RUNNER_TIMEOUT_HEARTBEAT" {
      printf "%s%s", sep, $1; sep = " "
    }' "$ATST_ALERT_STATUS_FILE" 2>/dev/null)
fi

fail_count=${ATST_HEARTBEAT_LINE_FAIL_COUNT:-}
[[ "$fail_count" =~ ^[1-9][0-9]{0,2}$ ]] || fail_count=3
if atst_line_send_failing "$fail_count"; then
  keys="${keys:+$keys }LINE_SEND_FAILED"
fi

# Bounded so a slow service never overlaps the next minute's run (check_all.sh cuts it at 60 seconds).
# The curl config: url only for the ping (GET), url and data-raw for /fail (POST). data-raw, not data:
# a body starting with @ is never read as a file name.
if [ -z "$keys" ]; then
  cfg=$(printf 'url = "%s"' "$url")
else
  body=$(printf '%s' "$keys" | LC_ALL=C tr -c 'A-Za-z0-9_ ' '_')
  body=${body:0:1000}
  cfg=$(printf 'url = "%s/fail"\ndata-raw = "%s"' "$url" "$body")
fi
curl -fs --max-time 10 --retry 3 --retry-connrefused --retry-max-time 40 -o /dev/null \
  -K <(printf '%s\n' "$cfg") 2>/dev/null
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "heartbeat: send failed (curl exit $rc)" 1>&2
fi
exit "$rc"
