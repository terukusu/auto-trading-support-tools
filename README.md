# Auto Trading Support Tools
このツール群は Linux + Wine + MetaTrader4/5 で構成する自動売買サーバーの構築と監視をサポートするツール群です。
とくに複数の MT4/5 を扱う手間を軽減するためのものです。  


このツールや関連する情報については無保証です。このツールや関連する情報を使用して被るいかなる損害も当方は一切責任を負いません。ご利用は自己責任となります。


このツール群の外側も含めた全体構成  
<img src="../../wiki/images/atst_outline.png" width="640px">  


自動売買において、最も最悪の事態は「決済されないこと」です。
MetaTraderのクラッシュやサーバーの予期せぬ再起動を検知して対処をすれば被害は最小で済みます。
そのためのツール群です。


* 対応している Linux
    * Ubuntu 20.04, 22.04, 24.04
    * Debian 11, 12, 13
    * ※ x86_64 の minimal 版が理想。デスクトップもフォントも入っていない最低限でまっさらなのが良い
    * ※ 実機で確かめたのは Ubuntu 24.04 (2026年10月)。ほかで不具合があれば Issue で教えてください


* Wine は 10 系に固定しています
    * Wine 11 系では MT4 のインストーラが起動しないため。詳細は [ADR 0001](docs/adr/0001-wine10-pin-and-win64.md)


## このツール群でできること
* まっさらな VPS に MetaTrader4/5 (以下MT4/5) を動かすのに必要なもの一式をインストール
* VPS再起動時にMT4/5を自動起動
* 以下のことを検知してLINEに通知
    * VPSの再起動
    * MT4/5 のクラッシュ・フリーズ
    * ソフトウェア更新有無(自動更新はしない)
    * ポジションの変化(新規、決済)
    * 価格、スプレッド、Pingの異常値
    * 価格データ(ティック)の途絶
    * 取引できない状態(接続断・自動売買ボタン OFF など)
    * 証拠金維持率の低下
* サーバーごと止まったときは、外部の監視サービスからメールで通知(任意)
* 落ちた・固まった MT4/5 を自動で起動し直す(任意、既定 OFF)


* [通知内容のサンプルはこちら](../../wiki/notification_sample)


<img src="../../wiki/images/mt4_on_linux_vps.png" width="480px"><br />
↑ こうなる。そしてこの状態を保っていることを監視するためのもの。


## このツールがインストール・設定するもの
* 既存パッケージの最新化
* 可能ならば swap 領域の作成
* vncserver + wm2
    * 要するに最小構成のGUI
* wine
    * Linux 上で Windows 用アプリを動かすソフト
* MT4 インストーラ の起動
    * MT4 のインストールは GUI での操作が必要なためインストーラ起動後は手動で進める必要あり
* スプレッド等のモニタリングデータをファイルに書き出すためのEA


詳しくは [仕様の詳細](docs/REFERENCE.md#導入で入るもの設定されるもの)

## Google の無料VPSでの例
まっさらな Linux VPS → 自動売買開始 → 監視 → 通知 までを一通りやってみましょうヽ(=´▽`=)ﾉ


[Google Cloud Platform](https://cloud.google.com/products/?hl=ja) の一番低スペックの[VPS(VMインスタンス)](https://cloud.google.com/compute/?hl=ja)は[無料で使えて](https://cloud.google.com/free/?hl=ja)十分実用に耐えるので、とりあえずこれで。


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


を、一通り行っている作業動画がこちら↓ (2019年の旧版。画面やコマンドが今と違うところがあるので、実際の作業は上の各ページに従ってください)  
[<img src="../../wiki/images/install_thumb.png" width="280px">](https://youtu.be/6kdOmCvU9ZU)

### おまけ
* 不正アクセス防止のところは GCP がよしなにやってくれてるので気にしなくてOK
    * 他の格安VPSの場合はちゃんとしないと驚くほど攻撃を受けるので注意。 [設定例](../../wiki/setup_iptables)
* [スマートフォンで口座を操作する](../../wiki/setup_mobile_mt)
    * 緊急時の手動決済などのための備え
* [スマートフォンで自動売買サーバーを操作する](../../wiki/setup_mobile_ssh)
    * これも緊急時の備え。見るだけなら ssh で十分です ([スマホからの日常確認](docs/REFERENCE.md#スマホからの日常確認-doctorsh--snapsh))
* [VPS の選び方](../../wiki/best_vps)
    * 年利 5% 有れば上等という投資・投機の世界でインフラ代は安ければ安いほど良いという話
* [Google 以外のVPSでの例](../../wiki/setup_vps)
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

設定が合っているかは `./doctor.sh` で確かめられます。


## もっと詳しく
* [仕様の詳細](docs/REFERENCE.md) — 設定の書き方、毎分の監視の動き、自己修復、旧 crontab からの移行、doctor.sh、スマホからの確認など
* [困ったとき](docs/RUNBOOK.md) — LINE に異常の通知が届いたときの確認と復旧の手順
