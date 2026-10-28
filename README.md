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


* 対象とするディストリビューション(x86_64, minimal 版)
    * Ubuntu 20.04, 22.04, 24.04
    * Debian 11, 12, 13
    * ※ サポート終了(EOL)した古い版(Ubuntu 14〜18 / Debian 8〜10 等)は切り捨て。当時は動作していたが現在は未サポート


* 現行版のインストール手順を実機で検証済みの環境
    * Ubuntu 24.04 / OpenVZ(カーネル共有型の格安VPS) / Wine 10.0 / MT4(Land Prime) — 2026年10月
    * ※ 上記以外のディストリビューションは「対象」だが現行版での実機検証はまだ。不具合があれば Issue で教えてください


* 過去の動作実績のある仮想化方式・カーネル
    * 格安VPSに多い仮想化方式 [OpenVZ](https://ja.wikipedia.org/wiki/OpenVZ) / Virtuozzo で使われるカーネル
        * 2.6.32-xxx 〜 6.x 系
    * 少しお高い VPS に多い仮想化方式 [KVM](https://ja.wikipedia.org/wiki/Kernel-based_Virtual_Machine) で使える最近のカーネル
        * 4.15.0 以降


* Wine は 10 系に固定しています
    * Wine 11 系では MT4 のインストーラが起動しないため(インストーラのデバッガ検出が誤作動する。MT5 でも同様の報告あり)。Wine 側で解決したら切り替えます
    * 詳細は [ADR 0001](docs/adr/0001-wine10-pin-and-win64.md)。追跡 Issue は [#66](../../issues/66)


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
    * WineHQ の stable 版を 10 系に固定してインストール(`/etc/apt/preferences.d/winehq-stable-pin`)
    * Wine の環境(`~/.wine`)は 64bit で作成。MT4 本体は 32bit アプリとしてその上で動く
    * 既に `~/.wine` が有る場合は消さずにそのまま使う(作り直すかは対話実行時にだけ確認する)
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

※ この動画は 2019 年に撮ったものです。Google Cloud のコンソールや MetaTrader の画面、インストールのコマンドなどが今とは違うところがあります。実際の作業は上の各ページの手順に従ってください。

### おまけ
* [外側からの監視(ハートビート)](../../wiki/setup_heartbeat)
    * サーバーそのものやネットワークのダウンを検知する。VPS が毎分外部サービスへ生存を知らせ、途絶えたら外部サービスが通知する
* 不正アクセス防止のところは GCP がよしなにやってくれてるので気にしなくてOK
    * 他の格安VPSの場合はちゃんとしないと驚くほど攻撃を受けるので注意。 [設定例](../../wiki/setup_iptables)
* [スマートフォンで口座を操作する](../../wiki/setup_mobile_mt)
    * 緊急時の手動決済などのための備え
* [スマートフォンで自動売買サーバーを操作する](../../wiki/setup_mobile_ssh)
    * これも緊急時の備え。スマートフォンからでもVMインスタンスのGUIに接続して操作できるようにしておく。
* [VPS の選び方](../../wiki/best_vps)
    * メモリ・OS・仮想化方式・場所などの選ぶときの考慮事項と、年利 5% 有れば上等という投資・投機の世界でインフラ代は安ければ安いほど良いという話
* [Google 以外のVPSでの例](../../wiki/setup_vps)
* [WindowsのRDPを使ってVMインスタンスの GUI にリモート接続する方法](../../wiki/setup_xrdp)
* [VMにデスクトップ環境であるLXDEを導入する方法](../../wiki/setup_lxde)


## 既にLinux + Wine + MetaTrader4/5 で自動売買をしている人向けの紹介

まずは crontab と、監視する MT4/5 を書く設定ファイル `~/.atst/config` です。設定が合っているか確かめたいときは、`doctor.sh` で診断できます([自己診断](#自己診断-doctorsh))。

crontab (`templates/crontab.txt` と同じ内容)
```
MAILTO=""
PATH="%%ATST_HOME%%:/bin:/usr/bin:/usr/local/bin" ← %%ATST_HOME%% の部分はインストール時に auto-trading-support-tools のパスに置換される

0 9 * * * check_daily.sh
* * * * * check_all.sh

@reboot    run_with_targets.sh mtctl.sh start
30 6 * * * run_with_targets.sh truncate_monitoring.sh
30 8 * * * run_with_targets.sh report_image.sh
```

`~/.atst/config` (ファイルの末尾に書きます)
```
# 監視する MetaTrader の名前 (インストール先のフォルダ名)。bash の配列で、名前ごとに ' か " で囲み、空白で区切る。
ATST_TARGETS=('Land Prime')
```

こんな感じで設定しておけば、再起動時とMT4/5プロセスが落ちたときや、ポジションの新規や決済、値動きやスプレッド、Pingに異常が有った時ににLINEへ通知してくれます。  

* `check_all.sh` は毎分の監視(再起動・約定・プロセス・監視データ・Ping・値動き・スプレッド・ハートビート)を 1 回ずつ順番に実行します。crontab の毎分の行はこの 1 行だけです。
* `run_with_targets.sh` は、`@reboot` のMT4/5の自動起動、監視データの整理、画像の通知のジョブに、`ATST_TARGETS` の名前を付けて実行します。


### 監視するMT4/5の指定 (ATST_TARGETS)

* 「Land Prime」となっている部分はMT4/5がインストールされているフォルダ名なら何でもよく、複数指定可能です。例: `ATST_TARGETS=('Land Prime' 'MetaTrader 5' 'MetaTrader 4')`
* 指定された名前に該当するMT4/5のインストールフォルダを前方一致で検索するので、フォルダ名の先頭の一部を記載しておけばOKです。
    * 既定のインストーラ(Land Prime)でMT4を入れると、フォルダ名は "Land Prime MetaTrader 4 Terminal" になるので、前方一致する "Land Prime" を指定すればよい。
* 名前は文字どおりに前方一致で比べ、正規表現としては扱いません(`.` `*` `(` `^` `|` なども普通の文字です)。大文字小文字は区別しません。
* 名前に `'` を含むときは、その名前を `"` で囲みます。例: `ATST_TARGETS=("Bob's MT4" 'MetaTrader 5')`
* `ATST_TARGETS` に該当する MT4/5 が見つからない場合は、その MT4/5 の監視と自動起動が効いていないことを LINE に通知します(check_process.sh)。
* `ATST_TARGETS` が未設定・空のときや、書き間違えて読み込めなかったときは、LINE に「監視対象が設定されていません」が届きます(MT4/5ごとの監視と約定の通知、再起動時のMT4/5の自動起動が止まります)。この通知が来たら、`~/.atst/config` の `ATST_TARGETS` の行の引用符と括弧の閉じ忘れを確認してください。通知が届いていた場合は、設定が読み込まれると復帰の通知が 1 回届きます。
* 旧形式の crontab (`TARGET="('Land Prime')"` と `wrapper.sh "$TARGET" ...` の行)は `ATST_TARGETS` を使わず、従来どおり crontab の `TARGET` を使います。


### 毎分の監視 (check_all.sh) の動き

* 1 つのチェックが失敗しても、残りのチェックは実行します。
* 1 つのチェックは `ATST_CHECK_TIMEOUT` 秒(1〜300、既定 40。`~/.atst/config` の末尾に `ATST_CHECK_TIMEOUT=60` のように書いて変更できます。範囲外の値は既定値になります)で打ち切り、「チェックが ... 秒で終わらず打ち切りました」と LINE に通知します(時間内に終わるようになると復帰を通知します)。
* 前の回がまだ終わっていないときは、その分は何もしないで終わります(重なって動きません)。前の回が約 22 分(既定。`ATST_CHECK_TIMEOUT` に応じて変わります)以上終わらないと、「毎分の監視 (check_all.sh) が ... 止まっています」(RUNNER_STUCK)と LINE に通知します。
* その回の通知(発生・復帰・再起動の検出・打ち切り)は、1 通にまとめて LINE に届きます(【ホスト名】は先頭に 1 つ、通知の間は空行です)。
    * 1 回目のチェック群が終わった時点で 1 通送ります。2 回目の約定のチェックやハートビートで打ち切りが出たときだけ、回の最後にもう 1 通届きます。
    * 通知は、従来より最大で 1 回目のチェック群の実行時間分(通常は数秒〜数十秒、打ち切りが重なると数分)遅れます。
    * 約定の通知と、「毎分の監視が止まっています」(RUNNER_STUCK)の通知は、まとめずにその場で個別に届きます。
    * まとめた通知が LINE の 1 メッセージの上限(5000 字)を超えるときは、通知の区切りで分けて送ります。
* 約定のチェックは 1 回目の開始から `ATST_ORDER_CHECK_INTERVAL` 秒(0〜50、既定 30。こちらも `~/.atst/config` の末尾に書きます)後にもう一度実行するので、従来どおり毎分 2 回です。
* ハートビート(`heartbeat.sh`)は `check_all.sh` の最後に送ります。外部サービス側の猶予(grace)は **3 分以上**を推奨します。


### 既存の crontab からの移行

旧形式の crontab (`TARGET="(...)"` と `wrapper.sh "$TARGET" check_*.sh` の行を並べたもの)のままでも、これまでどおり動きます。急いで移行する必要はありません。新形式に変えるときは、次の順で行います。

1. `~/.atst/config` の**末尾に** `ATST_TARGETS=(...)` を 1 行追記します。括弧の中身は旧 crontab の `TARGET="(...)"` の括弧の中身をそのまま使います(`TARGET="('Land Prime')"` なら `ATST_TARGETS=('Land Prime')`)。先頭や途中に書くと、書き間違えたときにそれより後の設定(LINE の設定など)が読まれず、通知も届かなくなるので、必ず末尾に書きます。
2. `crontab -e` で旧形式の行を消し、新しい行を書きます。
    * 消す行: `TARGET=` の行、`wrapper.sh "$TARGET"` の行すべて(`sleep 10;` `sleep 40;` `sleep_random.sh;` が付いたものも含む)、`check_reboot.sh` の行、`heartbeat.sh` の行。
    * 書く行: `* * * * * check_all.sh` の 1 行と、`@reboot` / `30 6 * * *` / `30 8 * * *` の `run_with_targets.sh` の 3 行(上の crontab の例のとおり)。`check_daily.sh` の行はそのままです。
    * 独自に追加した行が無ければ、手で直す代わりに `setup_cron.sh` を実行し、「Overwrite it? (Y/n)」に `Y` と答えて新しいテンプレートに上書きしてもかまいません(`n` では追記されず、何も変わりません)。ただし crontab 全体が置き換わります。
3. `crontab -l` で内容を確認します。1〜2 分後に `ls -l ~/.atst/check_all.started` で更新時刻が直近になっていて、「監視対象が設定されていません」の通知が来ていなければ完了です。

注意:
* 移行の途中で旧行と新行が同時にあっても、毎分の監視の通知は重複しません(旧形式の行が出す通知は、従来どおりその場で個別に届きます)。ただし共存は短い間にしてください(同じチェックが 1 分に 2 回動くため、しきい値付近で発生・復帰の通知が出やすくなります。LINE の応答が遅いと、打ち切りの通知が出ることもあります)。
* `@reboot`、`truncate_monitoring.sh`、`report_image.sh`、`check_daily.sh` の行は、旧形式と新形式の両方に残すと 2 回動きます。旧形式の行は必ず消してください。
* 元に戻すときは、新しい行を消して旧形式の行に戻せばかまいません。
* `ATST_TARGETS` が未設定のままだと、再起動時のMT4/5の自動起動(`@reboot` の行)も動きません。移行の前に必ず設定してください。
* 移行後に動かないときや、設定が合っているか確かめたいときは、`doctor.sh` を実行してください([自己診断](#自己診断-doctorsh))。

`setup_cron.sh` の動き:
* crontab が空のときは、確認なしで新しいテンプレートを登録します。
* 旧形式の行があれば、移行の案内と、旧 `TARGET` の値(`~/.atst/config` に書く 1 行の形)を表示します。旧形式の行は自動では消しません。
* atst の行(`check_*.sh`、`heartbeat.sh`、`wrapper.sh` など)がある crontab には、二重登録になるため追記しません。atst 以外の `check_*.sh` の行も atst の行とみなします。
* 入力がない(標準入力が閉じている)ときは、crontab を変更しません。
* crontab の書き込みやテンプレートの読み込みに失敗したときは、終了コード 2 で終わります。


`@reboot` の行は再起動時のMT4/5の自動起動設定です。

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

mtctl.sh のメッセージ(`list` の 1 行目、`status` の各行、`stop` / `start` で対象が見つからないときの行)には、判定に使った WINEPREFIX が ` (WINEPREFIX=...)` の形で付きます。`-q` のときはこれまでどおり何も出しません。

### 自己診断 (doctor.sh)

`./doctor.sh` (引数なし) で、atst の設定と監視の状態を項目ごとに 1 行で表示します。**読み取り専用**で、ファイル・crontab・MT4/5・Wine を一切変更せず、LINE への送信やネットワークアクセスもしません (`wine --version` と `crontab -l` を実行するだけです。`~/.atst/config` が無い初回だけは、共通処理が雛形を作ります)。

各行は `OK` / `NG` / `--` で始まります。`--` は「未設定・対象なし・表示のみ (判定しない)」です。補足の行は空白 2 個で字下げして表示し、最終行は件数のまとめです。NG が 1 件以上あれば終了コード 1、無ければ 0 です (`--` は終了コードに影響しません)。引数を付けると使い方を表示して終了コード 1 で終わります。

見る項目:
1. `wine --version`: wine が PATH にあり、版を表示できるか。
2. `arch`: 使用中の WINEPREFIX (config 読み込み後) があり、`system.reg` の `#arch=` の値。
3. `WINEPREFIX`: 対話シェルの環境変数 (`env=`)、config 読み込み後 (`config=`)、環境変数を外して config を読んだ値 (`cron=`、cron で使われる値) を並べ、`config=` と `cron=` が違えば NG (文字列で比較するので、シンボリックリンク経由で同じ場所を指していても NG になります)。
4. `target` / `mt`: `ATST_TARGETS` の各名前が検出した MT4/5 に前方一致するか (未設定・空は NG)。どの名前にも選ばれない MT4/5 は `--` (監視対象外) で表示します。前方一致で複数に当たるときは、check_*.sh と同じく最初の 1 つだけが監視対象です。
5. `process`: 対象の MT4/5 が起動しているか。
6. `ea` / `csv`: 監視 EA (`TerminalMonitoring.ex4` / `.ex5`) が置かれているか、`terminal_monitoring.csv` の最終行が `ATST_MONITORING_THRESHOLD` 秒より新しいか (check_monitoring.sh と同じ基準)。
7. `crontab -l`: 新形式 (`check_all.sh`) なら OK、旧形式 (`wrapper.sh`) のみなら OK で「旧形式」と添えます。両方ある (混在)・どちらも無いときは NG。
8. `line_error.log`: `~/.atst/line_error.log` の LINE 送信失敗の見出し行 (末尾 5 件)。表示のみです。
9. `.line_token` / `.line_id` / `.imgbb_key`: 存在と権限 (600 でなければ NG)。`.imgbb_key` は任意です。
10. `heartbeat`: `ATST_HEARTBEAT_URL` (外形監視) が設定されているか。疎通確認はしません。

NG の例:
```
NG WINEPREFIX env=~/.wine32 config=~/.wine32 cron=~/.wine
  interactive shell and cron use different WINEPREFIX; set WINEPREFIX in ~/.atst/config
NG crontab -l mixed: both check_all.sh and wrapper.sh
NG .line_token mode 644 (must be 600): ~/.atst/.line_token
```

トークン・キー・URL は末尾 4 文字だけ (`****abcd`) を表示し、LINE ID は表示しません。ホームディレクトリは `~` で表示するので、出力はそのまま Issue に貼れます (貼る前に念のため目で確認してください)。
