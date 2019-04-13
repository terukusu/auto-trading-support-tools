#!/bin/bash
#
# 1分ごとにcronで実行するスクリプトの実行タイミングを散らすためのスリープ
#

. "$(cd "$(dirname $0)" && pwd)/common.sh"

atst_random_sleep $ATST_CHECK_RANDOM_DELAY_MAX
