#!/bin/bash
#
# 外形監視のハートビート。ATST_HEARTBEAT_URL (Healthchecks.io などの ping URL) に毎分アクセスします。
# アクセスが途絶えると (VPS やネットワークの停止、cron の停止) 外部サービスが通知します。
# URL が設定されていなければ何もしません。
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ -z "$ATST_HEARTBEAT_URL" ]; then
  exit 0
fi

# Bounded so a slow service never overlaps the next minute's run. The URL is passed through a config
# fd, not argv, so other processes can't read it from ps (anyone with it can report us alive).
curl -fsS --max-time 10 --retry 3 --retry-connrefused --retry-max-time 40 -o /dev/null \
  -K <(printf 'url = "%s"\n' "$ATST_HEARTBEAT_URL")
