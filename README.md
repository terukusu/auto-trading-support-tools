# Auto Trading Support Tools
このツール群は Linux + Wine + MetaTrader4/5 で構成する自動売買サーバーの構築と監視をサポートするツール群です。
とくに複数の MT4/5 を扱う手間を軽減するためのものです。  


このツールや関連する情報については無保証です。このツールや関連する情報を使用して被るいかなる損害も当方は一切責任を負いません。ご利用は自己責任となります。


このツール群の外側も含めた全体構成  
<img src="../../wiki/images/atst_outline.png" width="640px">  


自動売買において、最も最悪の事態は「決済されないこと」です。
MetaTraderのクラッシュやサーバーの予期せぬ再起動を検知して対処をすれば被害は最小で済みます。
そのためのツール群です。


* 対応している Linux のディストリビューション
    * Ubuntu
    * Debian
    * ※ minimal版が理想。デスクトップもフォントも入っていない最低限でまっさらなのが良い


* 動作確認環境は以下のディストリビューションの x86_64, minimal 版
    * Ubuntu 14.04, 16.04, 18.04
    * Debian 8, 9


* 動作確認環境のカーネルバージョン
    * 格安VPSに多い仮想化方式 [OpenVZ](https://ja.wikipedia.org/wiki/OpenVZ) で使われるカーネル
        * 2.6.32-xxx
        * 3.10.0-xxx
    * 少しお高い VPS に多い仮想化方式 [KVM](https://ja.wikipedia.org/wiki/Kernel-based_Virtual_Machine) で使える最近のカーネル
        * 4.15.0-xxxx


## このツール群でできること
* まっさらな VPS に MetaTrader4/5 (以下MT4/5) を動かすのに必要なもの一式をインストール
* VPS再起動時にMT4/5を自動起動
* 以下のことを検知してLINEに通知
    * VPSの再起動検知
    * MT4/5 のクラッシュ検知
    * ソフトウェア更新有無(自動更新はしない)
    * ポジションの変化(新規、決済)の検知
    * 価格、スプレッド、Pingの異常値検知


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
    * MT5を使う場合は[インストーラの起動も手動](../../wiki/install_mt#mt5-%E3%82%92%E3%82%A4%E3%83%B3%E3%82%B9%E3%83%88%E3%83%BC%E3%83%AB%E3%81%99%E3%82%8B%E6%89%8B%E9%A0%86)
* スプレッド等のモニタリングデータをファイルに書き出すためのEA

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


を、一通り行っている作業動画がこちら↓  
[<img src="../../wiki/images/install_thumb.png" width="280px">](https://youtu.be/6kdOmCvU9ZU)

### おまけ
* [Stackdriver で外側からの監視](../../wiki/setup_stackdriver)
    * サーバーそのものやネットワークのダウンを検知する
* 不正アクセス防止のところは GCP がよしなにやってくれてるので気にしなくてOK
    * 他の格安VPSの場合はちゃんとしないと驚くほど攻撃を受けるので注意。 [設定例](../../wiki/setup_iptables)
* [スマートフォンで口座を操作する](../../wiki/setup_mobile_mt)
    * 緊急時の手動決済などのための備え
* [スマートフォンで自動売買サーバーを操作する](../../wiki/setup_mobile_ssh)
    * これも緊急時の備え。スマートフォンからでもVMインスタンスのGUIに接続して操作できるようにしておく。
* [オススメVPS](../../wiki/best_vps)
    * 年利 5% 有れば上等という投資・投機の世界でインフラ代は安ければ安いほど良いという話
* [Google 以外のVPSでの例](../../wiki/setup_vps)


## 既にLinux + Wine + MetaTrader4/5 で自動売買をしている人向けの紹介

まずは crontab.
```
MAILTO=""
PATH="%%ATST_HOME%%:/bin:/usr/bin:/usr/local/bin" ← %%ATST_HOME%% の部分はインストール時に auto-trading-support-tools のパスに置換される

# List of MetaTrader which should be Monitored.
# It consists of space separated, single quoted MetaTrader name.
# ex. "('Land-FX' 'MetaTrader 5' 'MetaTrader 4')"
TARGET="('Land-FX')"

0 9 * * * check_daily.sh
* * * * * check_reboot.sh

@reboot    wrapper.sh                  "$TARGET" mtctl.sh start
30 6 * * * wrapper.sh                  "$TARGET" truncate_monitoring.sh
30 8 * * * wrapper.sh                  "$TARGET" report_image.sh
*  * * * * sleep 10; wrapper.sh        "$TARGET" check_order.sh
*  * * * * sleep 40; wrapper.sh        "$TARGET" check_order.sh
*  * * * * sleep_random.sh; wrapper.sh "$TARGET" check_monitoring.sh
*  * * * * sleep_random.sh; wrapper.sh "$TARGET" check_process.sh
*  * * * * sleep_random.sh; wrapper.sh "$TARGET" check_ping.sh
*  * * * * sleep_random.sh; wrapper.sh "$TARGET" check_price.sh
*  * * * * sleep_random.sh; wrapper.sh "$TARGET" check_spread.sh
```

こんな感じで設定しておけば、再起動時とMT4/5プロセスが落ちたときや、ポジションの新規や決済、値動きやスプレッド、Pingに異常が有った時ににLINEへ通知してくれます。  


「land-fx」となっている部分はMT4/5がインストールされているフォルダ名なら何でもよく、複数指定可能。  指定された名前に該当するMT4/5のインストールフォルダを前方一致で検索するのでフォルダ名の先頭の一部を記載しておけばOK.


@reboot の行は再起動時のMT4/5の自動起動設定です。

mtctl.sh は 複数の MT4/5 の一覧・起動・終了・状態確認ができるスクリプトです。使い方は↓こん感じ。
```
Usage: mtctl.sh [-qsh] <list|start|status|stop|monitor> <MetaTrader Name1> [<MetaTrader Name2> ...]
	list: list MetaTrader installed
	start: start MetaTrader
	status: print status of specified MetaTrader
	stop: stop MetaTrader
	monitor: preview monitoring data file.
	<MetaTrader Name>: folder name MetaTrader installed. It's searched in a forward match. (ex: "MetaTrader 4")
	-s: when list, show running status.(slow)
	-q: quiet mode. print nothing.
	-h: help. print this message.
```
