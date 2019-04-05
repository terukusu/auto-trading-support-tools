#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"

echo "LINEへの通知を送るための設定をします。"
echo ""

while [ 1 ]; do
    echo "LINE トークンを入力してください。43文字の文字列です。例：n3DganilkwSjpi...."
    echo ""
    echo -n "> "
    read line_token

    data_len=$(echo -n "$line_token" | wc -c)

    if [ $data_len -eq 43 ]; then
        echo $line_token > "$TRD_CONFIG_DIR/.line_token"
        break
    fi

    echo "トークンの値が不正です。もう一度入れ直してください"
done

echo ""

if [ -f "$TRD_CONFIG_DIR/.line_token" ]; then
    echo "LINE通知の設定が完了しました。テストメッセージを送信しますか？[Y/n]"
    echo ""
    echo -n "> "
    read answer

    if [ "${answer,,}" != "n" ]; then
        echo "LINE へメッセージを送信中...."
        echo Hello! | "$TRD_ABS_PWD/send_to_line.sh"
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
