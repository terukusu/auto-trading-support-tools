# auto-trading-support-tools
Ubuntu+Wine+MetaTrader4/5 の自動売買サーバーの監視をサポートするツール群です。
Ubuntu14〜18 くらいまではおそらく大丈夫。動作確認は主に16, 18でおこなっています。

## このツール群でできること
* まっさらな VPS に MetaTrader4(or 5) を動かすのに必要なもの一式のインストール
* 起動時にMT4/5を自動起動
* 以下のことを検知してLINEに通知
    * VPSの再起動
    * MT4/5 のクラッシュ

## 備考
* インストールされるもの
    * 既存パッケージの最新化
    * 可能ならば swap 領域の作成
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

## Google Compute Engin の無料VMインスタンスでの例
### 前提
* Google Cloud Platform (GCP) へのの登録(無料)は完了している
* gcloud コマンドが[インストール済み](https://cloud.google.com/sdk/downloads?hl=JA)
* gcloudコマンドが認証済で、そのプロジェクトがデフォルトプロジェクトになっている

### やってみよー
ログイン
```
$ gcloud auth login
```
<br />

プロジェクト作成(既存のプロジェクトを使うなら不要)
```
$ gcloud projects create trade-00001 --name=trade --set-as-default
```
<br />

作成したPJが捜査対象になっていることを確認
```
$ gcloud config list
[core]
account = <ログインしたアカウント>
disable_usage_reporting = False
project = trade-00001 ← ここが作成したPJになっているか確認

Your active configuration is: [default]
```
<br />

作成したPJで課金を有効にする。(Web の GCPコンソールからでもOK)
```
$ gcloud alpha billing accounts list
$ gcloud alpha billing projects link my-project \
      --billing-account 0X0X0X-0X0X0X-0X0X0X ← ここは支払いアカウントにしたいアカウントIDに置き換えること
```
<br />

VM 作成(ローカルマシンで実行)
```
$ gcloud compute instances create tradevm --machine-type f1-micro --zone us-east1-b --image-project ubuntu-os-cloud --image-family ubuntu-minimal-1804-lts --boot-disk-type pd-standard --boot-disk-size 30
.....

NAME     ZONE        MACHINE_TYPE  PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP     STATUS
tradevm  us-east1-b  f1-micro                   xx.xxx.x.x   xxx.xxx.xxx.xxx  RUNNING
```
※ ディスク容量が少なすぎてパフォーマンスが・・・のようなエラーメッセージが出るが気にせず進めてOK
<br />

VMインスタンスへSSHログイン
```
$ gcloud compute ssh <任意のユーザー名>@tradevm
```
※ 任意のユーザー名のところは英数字で。今後も同じものを使うのであまり投げやりな名前にしないように  
※ 初回の場合はここでSSHの暗号化鍵の生成が行われるが、よしなに肯定的に進めればOK
<br />


圧縮展開ソフトのインストール （ここからVM上での作業）
```
$ sudo apt update
$ sudo apt install -y unzip
```
<br />

auto-tradeing-support-tools をダウンロード＆展開
```
$ wget https://github.com/terukusu/auto-trading-support-tools/archive/master.zip
$ unzip master.zip
$ mv auto-trading-support-tools-master auto-trading-support-tools
```

MetaTraderに必要なもののインストール （と、ｓｗａｐ領域の作成と、環境変数の設定と、日本語設定）
```
$ sudo auto-trading-support-tools/install_required_for_mt.sh
.....
$ ｅｘｉｔ ← 言語設定を反映させるために一度切断
```
※ タイムゾーン聞かれるので 「Asia」 → 「Tokyo」 と選択する
※ 変更を加えるファイルは ~/.bashrc と root の ｃｒｏｎｔａｂ 。それぞれ必要な環境変数追加と念の為の起動時の /var/run/sshd の作成。

再度ログイン。GUIの設定を行う
```
$ gcloud compute ssh --ssh-flag="-L5901:localhost:5901" teru@tradevm ← これはローカルマシンで実行

↓ ここからVPS上の作業
$ vncserver -geometry 1280x800 -localhost -nolisten tcp 

Password: ← リモートからGUIに接続する際のパスワードをここで決めて入れる
Verify:
```

Wineの設定

$ vncserver -geometry 1280x800 -localhost -nolisten tcp
