#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"

echo "LINEへの通知を送るための設定をします。"
echo ""

echo "LINE トークンを入力してください。例：n3DganilkwSjpi...."
echo ""
echo -n "> "
read line_token

echo $line_token > "$ATST_CONFIG_DIR/.line_token"

echo ""

echo "LINE ユーザーIDもしくはグループIDを入力してください。例：Uccf0eb6...."
echo ""
echo -n "> "
read line_id

echo $line_id > "$ATST_CONFIG_DIR/.line_id"
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
            echo "失敗しました。設定をやり直してください。"
        fi
    fi
else
    echo "LINE通知の設定は失敗しました。もう一度やり直してください。"
fi

exit 0
