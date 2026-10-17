#!/bin/bash
#
# レポート画像のアップロード先に ImgBB を使うための設定をします。
# API キーは https://api.imgbb.com/ で取得します (無料のアカウントが要ります)。
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "レポート画像のアップロード先に ImgBB を使うための設定をします。"
echo "API キーは https://api.imgbb.com/ の「Get API key」で取得してください (無料のアカウントが要ります)。"
echo "何も入力せずに Enter を押すと、ImgBB の設定を消します (Litterbox と Uguu を使います)。"
echo ""
echo -n "> "
read -r imgbb_key
imgbb_key=$(printf '%s' "$imgbb_key" | tr -d '[:space:]')

if [ -z "$imgbb_key" ]; then
  rm -f "$ATST_CONFIG_DIR/.imgbb_key"
  echo "ImgBB の設定を消しました。"
  exit 0
fi

# secrets: readable only by the owner
( umask 077; printf '%s\n' "$imgbb_key" > "$ATST_CONFIG_DIR/.imgbb_key" )
chmod 600 "$ATST_CONFIG_DIR/.imgbb_key"
echo ""

echo "テスト用の小さな画像を ImgBB にアップロードして確かめます (1 分で消えます)。"
test_image=$(mktemp "$ATST_CONFIG_DIR/imgbb_test.XXXXXX") || exit 1
trap 'rm -f "$test_image"' EXIT
# 1x1 PNG
printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d > "$test_image"

response=$(curl --max-time 60 --connect-timeout 10 -4 -s -w "\n%{http_code}" \
  -F "key=<"<(printf '%s' "$imgbb_key") -F "expiration=60" \
  -F "image=@$test_image" "https://api.imgbb.com/1/upload" 2>/dev/null)
code=${response##*$'\n'}
url=$(atst_json_first_url "${response%$'\n'*}")

if [ "$code" == "200" ] && [ -n "$url" ]; then
  echo "成功しました。以降のレポート画像は ImgBB に置きます (${ATST_IMGBB_EXPIRATION:-604800} 秒で消えます)。"
else
  echo "失敗しました (HTTP $code)。API キーを確かめて、もう一度実行してください。"
  echo "キーは保存したままです。ImgBB に失敗したときは Litterbox と Uguu を使います。"
  exit 1
fi

exit 0
