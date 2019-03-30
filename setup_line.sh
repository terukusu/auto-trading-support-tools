#!/bin/bash

ABS_PWD=$(cd $(dirname "${BASH_SOURCE:-$0}"); pwd)

echo "LINEへの通知を送るための設定をします。"
echo ""

while [ 1 ]; do
    echo "LINE トークンを入力してください。172文字の文字列です。例：n3DganilkwSjpi...."
    echo ""
    echo -n "> "
    read line_token

    data_len=$(echo $line_token | fold -64 | openssl enc -d -base64 | wc -c)

    if [ "$data_len" == "128" ]; then
        echo $line_token > "$ABS_PWD/.line_token"
        break
    fi

    echo "トークンの値が不正です。もう一度入れ直してください"
done

echo ""

while [ 1 ]; do
    echo "LINE ユーザーIDを入力してください。 33文字の文字列です。例: Ucc4ba77b......"
    echo ""
    echo -n "> "
    read line_id

    data_len=$(echo ${line_id:1} | fold -64 | openssl enc -d -base64 | wc -c)

    if [ "$data_len" == "24" ]; then
        echo $line_id > "$ABS_PWD/.line_recipients"
        break
    fi

    echo "ユーザーIDの値が不正です。もう一度入れ直してください"
done

echo ""

if [ -f "$ABS_PWD/.line_token" -a -f "$ABS_PWD/.line_recipients" ]; then
    echo "LINE通知の設定が完了しました。テストメッセージを送信しますか？[Y/n]"
    echo ""
    echo -n "> "
    read answer

    if [ "$(echo $answer | tr N n)" != "n" ]; then
        echo "LINE へメッセージを送信中...."
        echo Hello! | "$ABS_PWD/send_to_line.sh"
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
