#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"

echo "LINEへの通知を送るための設定をします。"
echo ""

echo "LINE Messaging API のチャネルアクセストークン(長期)を入力してください。"
echo "(LINE Notify のトークンは使えません。手順は Wiki の「LINE への通知設定(LINE 側)」を参照)"
echo ""
echo -n "> "
read -r line_token

# secrets: readable only by the owner (also fixes files written by older versions)
( umask 077; printf '%s\n' "$line_token" > "$ATST_CONFIG_DIR/.line_token" )
chmod 600 "$ATST_CONFIG_DIR/.line_token"

echo ""

echo "LINE の送信先 ID (あなたのユーザー ID。U で始まる文字列。グループに送る場合はグループ ID) を入力してください。"
echo ""
echo -n "> "
read -r line_id

( umask 077; printf '%s\n' "$line_id" > "$ATST_CONFIG_DIR/.line_id" )
chmod 600 "$ATST_CONFIG_DIR/.line_id"
echo ""


echo ""

if [ -f "$ATST_CONFIG_DIR/.line_token" ]; then
    echo "LINE通知の設定が完了しました。テストメッセージを送信しますか？[Y/n]"
    echo ""
    echo -n "> "
    read answer

    if [ "${answer,,}" != "n" ]; then
        echo "LINE へメッセージを送信中...."
        echo Hello! | "$ATST_HOME/send_to_line.sh"
        if [ "$?" == "0" ]; then
            echo "送信しました。LINEを確認してください。"
        else
            echo "失敗しました。トークンとユーザー ID、公式アカウントを友だちに追加したかを確認して、設定をやり直してください。"
            echo "詳細: $ATST_CONFIG_DIR/line_error.log"
        fi
    fi
else
    echo "LINE通知の設定は失敗しました。もう一度やり直してください。"
fi

exit 0
