# 自動売買に必要なものをインストール

## 概要

まっさらな Google Compute Engine(GCP) に、自動売買ソフト MetaTrader4/5 を動作させるのに必要なパッケージのインストールと、設定を行います。

### この手順でインストール・設定されるもの

* 既存パッケージの最新化
* swap 領域の作成
* vncserver + wm2
  * 要するに最小構成のGUI
* wine
  * Linux 上で Windows 用アプリを動かすソフト


※ 注意： MT4/5本体は GUI で操作しながらインストールしなければならないため手動でインストールする必要が有ります

## 手順

圧縮展開ソフトのインストール  
VMインスタンスにSSHログインしたターミナル上での作業

```
$ sudo apt update
$ sudo apt install -y unzip
```


auto-tradeing-support-tools をダウンロード＆展開

```
$ wget https://github.com/terukusu/auto-trading-support-tools/archive/master.zip
$ unzip master.zip
$ mv auto-trading-support-tools-master auto-trading-support-tools
```


MetaTraderに必要なものをインストール

```
$ sudo ~/auto-trading-support-tools/install_required_for_mt.sh
.....
$ exit ← 言語設定を反映させるために一度切断
```

* 途中でタイムゾーンを聞かれるので 「Asia」 → 「Tokyo」 と選択する
* このスクリプトは swap領域の作成と、日本語設定と、環境変数の設定も行います
    * このスクリプトが自動的に変更を加えるファイル
        * ~/.bash_profile
            * 必要な環境変数追加
        * root の crontab
            * 念の為の起動時の /var/run/sshd の作成を設定(sshdの起動に必要)
