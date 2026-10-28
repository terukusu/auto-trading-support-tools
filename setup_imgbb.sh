#!/bin/bash
#
# 定期レポートの画像 (グラフ、有効にしたときはデスクトップ) を ImgBB に置くための設定をします。
# キーが無いときは画像を送らず、文字要約だけになります。
# API キーは https://api.imgbb.com/ で取得します (無料のアカウントが要ります)。
#

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "定期レポートの画像 (グラフ、有効にしたときはデスクトップ) を ImgBB に置くための設定をします。"
echo "API キーは https://api.imgbb.com/ の「Get API key」で取得してください (無料のアカウントが要ります)。"
echo "何も入力せずに Enter を押すと、ImgBB の設定を消します (画像は送らず、文字要約だけになります)。"
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
# 64x32 PNG. ImgBB refuses 1x1 images ("You have been forbidden to use this website.", code 103).
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAAARUlEQVR42u3XMQ0AIAxE0epgZcIWQmodRHRq+pJv4E2Xi7WzdQEAAAAAUAKc+1oHAAAAAFADWGIAAAAAf8ASAwAAAIwFfFhvFIhzDrjzAAAAAElFTkSuQmCC' | base64 -d > "$test_image"

response=$(curl --max-time 60 --connect-timeout 10 -4 -s -w "\n%{http_code}" \
  -F "key=<"<(printf '%s' "$imgbb_key") -F "expiration=60" \
  -F "image=@$test_image" "https://api.imgbb.com/1/upload" 2>/dev/null)
code=${response##*$'\n'}
url=$(atst_json_first_url "${response%$'\n'*}")

if [ "$code" == "200" ] && [ -n "$url" ]; then
  echo "成功しました。以降のレポート画像は ImgBB に置きます (${ATST_IMGBB_EXPIRATION:-86400} 秒で消えます)。"
  echo "デスクトップ画像も送るには ~/.atst/config に ATST_IMAGE_REPORT_DESKTOP=1 を書いてください (口座番号・残高が写ります)。"
else
  echo "失敗しました (HTTP $code)。API キーを確かめて、もう一度実行してください。"
  echo "キーは保存したままです。"
  exit 1
fi

exit 0
