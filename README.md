# Auto Trading Support Tools
Linux の VPS で MetaTrader4/5 (以下 MT4/5) の自動売買を動かし、止まったり取引できなくなったりしたら、すぐに LINE で知らせるためのツール群です。
まっさらな VPS への MT4/5 の導入も、コマンド 1 つでほぼ自動で行います。複数の MT4/5 をまとめて扱えます。


自動売買において、最も最悪の事態は「決済されないこと」です。
MetaTraderのクラッシュやサーバーの予期せぬ再起動を検知して対処をすれば被害は最小で済みます。
そのためのツール群です。


全体の構成  
<img src="../../wiki/images/atst_outline.png" width="640px">  


## このツール群でできること
* まっさらな VPS に、MT4/5 を動かすのに必要なもの一式をインストール
* VPS の再起動時に MT4/5 を自動で起動
* 次のことを検知して LINE に通知
    * VPS の再起動
    * MT4/5 が落ちた・固まった
    * ポジションの変化(新規、決済)
    * 価格・スプレッド・Ping の異常
    * 価格データ(ティック)の途絶
    * 取引できない状態(ブローカーとの接続断、自動売買ボタンの OFF など)
    * 証拠金維持率の低下
    * ソフトウェアの更新(自動では更新しない)
* VPS そのものやネットワークが止まったときも、外部の監視サービスから LINE に通知(推奨)
* 毎朝、稼働状況と値動き・スプレッドの要約を LINE に送る
* 落ちた・固まった MT4/5 を自動で起動し直す(任意、既定は OFF)

通知はすべて LINE に届きます。[通知内容のサンプルはこちら](../../wiki/notification_sample)


<img src="../../wiki/images/mt4_on_linux_vps.png" width="480px"><br />
↑ こうなる。そしてこの状態を保っていることを監視するためのもの。


## 必要なもの
* Linux の VPS
    * Ubuntu 20.04 / 22.04 / 24.04、Debian 11 / 12 / 13 (x86_64)。デスクトップもフォントも入っていない、まっさらな minimal 版が理想
    * メモリ 1GB 以上。Google Cloud の無料枠の VM でも動きます
    * 現行版を実機で確かめたのは Ubuntu 24.04 です。ほかで不具合があれば Issue で教えてください
* LINE のアカウント
    * 通知用の LINE 公式アカウントを無料で作ります(通知は月 200 通まで無料)
* MT4/5 を使えるブローカーの口座(まずはデモ口座で試せます)
* 外部の監視サービス(推奨。[Healthchecks.io](https://healthchecks.io/) の無料プランで足ります)


## 導入手順 (Google の無料VPSでの例)
まっさらな Linux VPS → 自動売買開始 → 監視 → 通知 までを一通りやってみましょうヽ(=´▽`=)ﾉ  
上から順に、各ページの手順どおりに進めれば導入できます。


1. [VMインスタンス作成](../../wiki/create_vm_gce)
1. [自動売買に必要なものをインストール](../../wiki/install_misc)
1. [VMインスタンスの GUI にリモート接続](../../wiki/connect_gui)
1. [MetaTrader をインストール・設定](../../wiki/install_mt)
1. [LINE への通知設定(LINE側)](../../wiki/create_line_token)
1. [LINE への通知設定(VM側)](../../wiki/setup_line)
1. [再起動検知やMT4/5クラッシュ検知を設定](../../wiki/setup_monitoring)
1. [自動売買を開始する](../../wiki/setup_ea)
1. [ポジション新規／決済、価格、スプレッド、Pingの異常検知を設定](../../wiki/setup_monitoring2)
1. [外側からの監視(ハートビート)を設定](../../wiki/setup_heartbeat) (推奨)


Google 以外の VPS でも手順はほぼ同じです。違うところは [Google 以外のVPSでの例](../../wiki/setup_vps) を見てください。


一通り行っている作業動画はこちら↓ (2019 年の旧版です。画面やコマンドが今と違うところがあるので、実際の作業は上の各ページに従ってください)  
[<img src="../../wiki/images/install_thumb.png" width="280px">](https://youtu.be/6kdOmCvU9ZU)


## 導入した後
* LINE に異常の通知が届いたら → [困ったとき (RUNBOOK)](docs/RUNBOOK.md) の、その通知の節を見る
* 設定や監視が正しく動いているか確かめたい → VPS で `doctor.sh` を実行する(読み取りだけで、何も変えません)
* 緊急時に備えて、スマートフォンからも操作できるようにしておく
    * [スマートフォンで口座を操作する](../../wiki/setup_mobile_mt)(手動決済など)
    * [スマートフォンで自動売買サーバーを操作する](../../wiki/setup_mobile_ssh)


### おまけ
* [VPS の選び方](../../wiki/best_vps)
    * 年利 5% 有れば上等という投資・投機の世界でインフラ代は安ければ安いほど良いという話
* [ファイアウォール(iptables)の設定例](../../wiki/setup_iptables)
    * Google 以外の格安VPSでは、ちゃんとしないと驚くほど攻撃を受けるので注意
* [WindowsのRDPを使ってVMインスタンスの GUI にリモート接続する方法](../../wiki/setup_xrdp)
* [VMにデスクトップ環境であるLXDEを導入する方法](../../wiki/setup_lxde)


## 既にLinux + Wine + MetaTrader4/5 で自動売買をしている人向けの紹介

まずは crontab.
```
MAILTO=""
PATH="%%ATST_HOME%%:/bin:/usr/bin:/usr/local/bin" ← %%ATST_HOME%% の部分はインストール時に auto-trading-support-tools のパスに置換される

0 9 * * * check_daily.sh
* * * * * check_all.sh

@reboot    run_with_targets.sh mtctl.sh start
30 6 * * * run_with_targets.sh truncate_monitoring.sh
30 8 * * * run_with_targets.sh report_image.sh
```

そして監視する MT4/5 を `~/.atst/config` の末尾に書きます。
```
ATST_TARGETS=('Land Prime')
```

こんな感じで設定しておけば、再起動時とMT4/5プロセスが落ちたときや、ポジションの新規や決済、値動きやスプレッド、Pingに異常が有った時ににLINEへ通知してくれます。  


「Land Prime」となっている部分はMT4/5がインストールされているフォルダ名なら何でもよく、複数指定可能。  指定された名前に該当するMT4/5のインストールフォルダを前方一致で検索するのでフォルダ名の先頭の一部を記載しておけばOK.


@reboot の行は再起動時のMT4/5の自動起動設定です。

mtctl.sh は 複数の MT4/5 の一覧・起動・終了・状態確認ができるスクリプトです。使い方は↓こん感じ。
```
Usage: mtctl.sh [-qsh] <list|start|restart|status|stop|monitor> <MetaTrader Name1> [<MetaTrader Name2> ...]
	list: list MetaTrader installed
	start: start MetaTrader
	restart: stop and start MetaTrader
	status: print status of specified MetaTrader
	stop: stop MetaTrader
	monitor: preview monitoring data file.
	<MetaTrader Name>: folder name MetaTrader installed. It's searched in a forward match. (ex: "MetaTrader 4")
	-s: when list, show running status.(slow)
	-q: quiet mode. print nothing.
	-h: help. print this message.
```

設定の書き方や監視の動きの細かいところは [仕様の詳細](docs/REFERENCE.md) にあります。


---
このツールや関連する情報については無保証です。このツールや関連する情報を使用して被るいかなる損害も当方は一切責任を負いません。ご利用は自己責任となります。
