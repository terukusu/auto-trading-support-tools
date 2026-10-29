#!/bin/bash
#
# 外形監視 (ハートビート) の URL を設定します。Healthchecks.io などで作ったチェックの ping URL を
# ~/.atst/.heartbeat_url (600) に保存し、テストの ping を 1 回送ります。
# 何も入力せずに Enter を押すとファイルを消します (config の ATST_HEARTBEAT_URL があればそれが使われます)。
# 入力が無いまま終わったとき (EOF) は何も変えません。
# URL を知っていれば誰でも生存を報告できるので、画面には末尾 4 文字しか出しません。
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

file="$ATST_CONFIG_DIR/.heartbeat_url"
tilde='~'
shown_file="$tilde/.atst/.heartbeat_url"  # shown instead of the home directory

echo "外形監視 (ハートビート) の URL を設定します。"
echo "VPS・ネットワーク・cron が止まったときや、監視が異常を検知している間 (LINE が届かないときも) に、"
echo "外部のサービスからメールなどで知らせてもらうためのものです (推奨。必須ではありません)。"
echo "Healthchecks.io でチェックを作り (Period 1 分、Grace 3 分以上)、その ping URL を貼り付けてください。"
echo "手順は Wiki の「外側からの監視」を参照してください。"
echo "何も入力せずに Enter を押すと、設定を消します。"
echo ""
echo -n "> "
url=""
if ! IFS= read -r url && [ -z "$url" ]; then
  echo ""
  echo "入力がありませんでした。何も変更していません。"
  exit 1
fi
# Leading and trailing spaces (and a CR) only; a space inside is refused below.
url="${url#"${url%%[![:space:]]*}"}"
url="${url%"${url##*[![:space:]]}"}"

if [ -z "$url" ]; then
  rm -f "$file"
  echo "設定を消しました ($shown_file)。"
  echo "config ($tilde/.atst/config) に ATST_HEARTBEAT_URL が書かれていれば、そちらが引き続き使われます。"
  exit 0
fi

# No space, " or \: the URL goes into a quoted curl config line (-K).
url_re='^https?://[^[:space:]"\\]+$'
host_re='^https?://[^/]'
valid=0
if [[ "$url" =~ $url_re ]]; then
  while [ "${url%/}" != "$url" ]; do
    url=${url%/}
  done
  [[ "$url" =~ $host_re ]] && valid=1
fi
if [ "$valid" -ne 1 ]; then
  echo "URL の形式が正しくありません (http:// か https:// で始まり、空白・\"・\\ を含まないこと)。何も変更していません。"
  exit 1
fi

# secrets: readable only by the owner
if ! { ( umask 077; printf '%s\n' "$url" > "$file" ) && chmod 600 "$file"; } 2>/dev/null; then
  echo "保存できませんでした: $shown_file"
  exit 1
fi
echo "保存しました: $(atst_mask_tail4 "$url") ($shown_file)"
echo ""

echo "テストの ping を 1 回送ります。"
# The URL goes through a config fd, not argv (P5). curl's own error text (with the host name) is dropped.
cfg=$(printf 'url = "%s"' "$url")
resp=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K <(printf '%s\n' "$cfg") 2>/dev/null)
rc=$?
code=${resp##*$'\n'}
[[ "$code" =~ ^[0-9]{3}$ ]] || code=000

if [ "$rc" -eq 0 ] && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
  echo "テスト ping 成功 (HTTP $code)。外部サービスの画面で届いたことを確認してください。"
  exit 0
fi
echo "テスト ping 失敗 (HTTP $code)。URL を確かめてもう一度実行してください。URL は保存したままです。"
exit 1
