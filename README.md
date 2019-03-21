# auto-trading-support-tools
Ubuntu+Wine+MetaTrader4/5 の自動売買サーバーの監視をサポートするツール群です。
Ubuntu14〜18 くらいまではおそらく大丈夫。動作確認は主に16, 18でおこなっています。

# このツール群でできること
* まっさらな VPS に MetaTrader4(or 5) を動かすのに必要なもの一式のインストール
* 起動時にMT4/5を自動起動
* 以下のことを検知してLINEに通知
    * VPSの再起動
    * MT4/5 のクラッシュ

# 備考
* インストールされるもの
    * 既存パッケージの最新化
    * vncserver + wm2
        * 要するにGUI
    * wine
        * Linux 上で Windows 用アプリを動かすソフト
    * 注意： MT4/5本体は GUI で操作しながらインストールする必要が有るため手動でインストールする必要有リ

* line 通知機能を使うには以下の準備が必要です
    * [LINE Developers](https://developers.line.biz/ja/services/messaging-api/)(登録無料) に登録
    * Messaging API を使うための設定
        * ↓を取得しておく必要有り
            * API にアクセスするためのトークン
            * メッセージ送信先である自分のユーザーID
                * LINE ID ではなくこういう感じの文字列 → Ucc4ba77baedb40a1603873976142c485

# Google Compute Engin の無料VMインスタンスでの例
