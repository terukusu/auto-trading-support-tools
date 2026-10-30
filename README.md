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
    * ティック(価格データ)の途絶の検知(ブローカーとの接続断・ログアウト・銘柄の配信停止など。週末は判定しない)
    * 取引できない状態の検知(ブローカーとの接続断・端末の自動売買ボタン OFF・閲覧専用のログイン・口座の EA 取引の禁止。週末は判定しない)


* [通知内容のサンプルはこちら](../../wiki/notification_sample)


<img src="../../wiki/images/mt4_on_linux_vps.png" width="480px"><br />
↑ こうなる。そしてこの状態を保っていることを監視するためのもの。


## このツールがインストール・設定するもの
* 既存パッケージの最新化
* 可能ならば swap 領域の作成
* vncserver + wm2
    * 要するに最小構成のGUI
    * VNC のパスワードはインストール時に英数字 8 文字を乱数で作り、最後の結果表示に `[ OK ] VNC password: ...` として 1 回だけ出します(途中で止まったときも、終了時に未表示なら 1 回出します)。控えてください(インストールの出力を `| tee` などでファイルに保存するとパスワードもそこに残ります)
    * 控え忘れたときは VPS 上で `vncpasswd` を実行して設定し直し、MetaTrader が動いていない時に `sudo systemctl restart vncserver@:1` します
    * 既に `~/.vnc/passwd` がある環境(再実行を含む)ではパスワードを変えません
    * 自分で決めたい場合は環境変数 `VNC_PASSWORD`(空白なしの 6〜8 文字。全角などは使わず ASCII の英数字・記号にしてください。VNC は先頭 8 バイトしか使いません)で渡せます。値は表示しません(シェルの履歴に残るので注意)。条件に合わない値なら何も変えずに止まります
* wine
    * Linux 上で Windows 用アプリを動かすソフト
    * WineHQ の stable 版を 10 系に固定してインストール(`/etc/apt/preferences.d/winehq-stable-pin`)
    * WineHQ の署名鍵は、スクリプトに埋め込んだ公式鍵の fingerprint と一致したときだけ登録する(一致しない・公開鍵 1 本だけでないときは `[error]` を出して、鍵もリポジトリ設定も残さず止まる。WineHQ のリポジトリを設定済みの機では照合しない。WineHQ が鍵を更新したときは、公式の 2 出典(`https://dl.winehq.org/wine-builds/winehq.key` を `gpg --show-keys` で見た値と、keyserver.ubuntu.com の同じ鍵の値)が一致することを確かめて、`install_required_for_mt.sh` の `WINE_KEY_FINGERPRINT` を更新する)
    * Wine の環境(`~/.wine`)は 64bit で作成。MT4 本体は 32bit アプリとしてその上で動く
    * 既に `~/.wine` が有る場合は消さずにそのまま使う(作り直すかは対話実行時にだけ確認する)
    * 環境変数 `ATST_INSTALL_NO_ZDRIVE=1` を付けて導入すると(例: `ATST_INSTALL_NO_ZDRIVE=1 bash init_atst.sh`)、Wine の `Z:` ドライブ(Windows 側から Linux の `/` 全体が見える)を外します。Windows 側のドライブとして `/` が見えなくなるだけの緩和策で、隔離ではありません(Wine は `\\?\unix\` 形式のパスなど別の経路で Unix のファイルを開けるため、悪意ある DLL までは防げません。本当の隔離は実行ユーザーの分離です)。なお winecfg でフォルダをホームにリンクすると、そのフォルダ経由で見えるようになります。新規導入向けの試験的な選択肢で、既定では外しません(既存環境は変わりません)。値は `1` のときだけ有効で、結果表示に `[ OK ] wine Z: drive: removed` が出ます
    * 既存環境で外すなら MetaTrader を止めてから `rm ~/.wine/dosdevices/z:`(戻すときは同じく止めてから `ln -s / ~/.wine/dosdevices/z:`)
    * MetaTrader を動かすユーザーを管理ユーザー(sudo できるユーザー)と分ける構成例は [docs/MT_USER_SEPARATION.md](docs/MT_USER_SEPARATION.md)(未検証の構成例。スクリプトは対応していません)
* MT4 インストーラ の起動
    * MT4 のインストールは GUI での操作が必要なためインストーラ起動後は手動で進める必要あり
    * インストーラは `~/.wine/drive_c/atst/installer/`(Windows からは `C:\atst\installer\`)に保存して起動します(`Z:` ドライブの有無に関係なく動くため。既定でもこの場所です)。以前の版が使った `~/.cache/wine` は残っていれば手で消してかまいません
    * 取得したインストーラの sha256 を表示する(`MetaTrader installer sha256: ...`。どの版を入れたかの記録用で、照合はしない)
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
1. [外側からの監視(ハートビート)を設定](../../wiki/setup_heartbeat)
    * 推奨(必須ではありません)。VPS・ネットワーク・cron の停止と、監視が異常を検知している状態(LINE が届かないときも)を、LINE とは別の経路(外部サービスのメールなど)で知らせます。`setup_heartbeat.sh` で URL を設定します。


を、一通り行っている作業動画がこちら↓  
[<img src="../../wiki/images/install_thumb.png" width="280px">](https://youtu.be/6kdOmCvU9ZU)

※ この動画は 2019 年に撮ったものです。Google Cloud のコンソールや MetaTrader の画面、インストールのコマンドなどが今とは違うところがあります。実際の作業は上の各ページの手順に従ってください。

### 導入スクリプトの配布について
* 「自動売買に必要なものをインストール」で実行する `init_atst.sh`（Wiki が参照する gist）は、このリポジトリの `scripts/init_atst.sh` と同じものです。
* リリース tag の zip を取得し、スクリプトに埋め込まれた sha256 と一致したときだけ展開して `install_required_for_mt.sh` を実行します。一致しない・取得できないときは `[error]` を出して何も展開せずに止まります。
* 展開先は従来どおり `auto-trading-support-tools-master/` です（既存の crontab はそのまま使えます）。
* 最新の master を試したい場合だけ `--channel master` を付けます（sha256 の照合はしません。`[warn]` が出ます）。
* リリースの手順は [docs/RELEASE.md](docs/RELEASE.md) にあります。

### おまけ
* 不正アクセス防止のところは GCP がよしなにやってくれてるので気にしなくてOK
    * 他の格安VPSの場合はちゃんとしないと驚くほど攻撃を受けるので注意。 [設定例](../../wiki/setup_iptables)
    * テンプレートは `templates/ip_rules_v4.txt` / `ip_rules_v6.txt`。sshd のポートは `%%SSH_PORT%%` になっているので、`sudo sshd -T | grep -i '^port '` で確かめたポートで `./setup_iptables.sh --port <ポート> > rules.v4`(IPv6 は `--v6` を付けて `> rules.v6`)を実行し、置き換えた結果をファイルに保存します。このスクリプトは表示するだけで、ルールを適用しません
    * HTTP/HTTPS の行はコメントアウトしてあります。公開サイトを同居させるときだけ行頭の `#` を外します
    * 適用は `sudo iptables-restore --test < rules.v4` で確かめてから(sshd と ICMP の行は hashlimit を使うので、対応していないカーネルではここで失敗します。その場合は適用しないでください)、今の ssh 接続を開いたまま行い、別の端末から新しい ssh 接続ができることを確かめてから `iptables-persistent` で永続化します(新しいイメージでは先に `sudo apt-get update` しないとパッケージが見つからないことがあります。手順の詳細は Wiki)
* [スマートフォンで口座を操作する](../../wiki/setup_mobile_mt)
    * 緊急時の手動決済などのための備え
* [スマートフォンで自動売買サーバーを操作する](../../wiki/setup_mobile_ssh)
    * これも緊急時の備え。スマートフォンからでもVMインスタンスのGUIに接続して操作できるようにしておく。
    * 見るだけなら ssh で十分です ([スマホからの日常確認](#スマホからの日常確認-doctorsh--snapsh))
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

こんな感じで設定しておけば、再起動時とMT4/5プロセスが落ちたときや、ポジションの新規や決済、値動きやスプレッド、Pingに異常が有った時や、ティックが途絶えた時、取引できない状態が続いた時にLINEへ通知してくれます。  

* `check_all.sh` は毎分の監視(再起動・約定・プロセス・監視データ・ティック・取引可否・Ping・値動き・スプレッド・ハートビート)を 1 回ずつ順番に実行します。crontab の毎分の行はこの 1 行だけです。
* `run_with_targets.sh` は、`@reboot` のMT4/5の自動起動、監視データの整理、定期レポート (値動き・スプレッドの要約と画像) のジョブに、`ATST_TARGETS` の名前を付けて実行します。
* `report_image.sh` は毎朝、MT ごとの値動き・スプレッドの文字要約を送ります。ImgBB の API キー (`setup_imgbb.sh`) があればグラフ画像を付け、`~/.atst/config` に `ATST_IMAGE_REPORT_DESKTOP=1` を書くとデスクトップ画像も付けます (既定は送りません。口座番号・残高が写るため)。画像は ImgBB に置かれ、24 時間で消えます (`ATST_IMGBB_EXPIRATION` で変更できます)。


### ~/.atst/config の書き方

* 今の `~/.atst/config` (雛形のまま、または追記したもの) はこれまでどおり読めます。
* 全部の行を `KEY=値` / `KEY="値"` / `KEY='値'` / `ATST_TARGETS=('名前' "名前")` (1 行) とコメント・空行だけで書くと、config を bash として source せずに値だけを読みます（読み込みの段階ではコマンドを実行しません。ただし値はそのまま各スクリプトに渡るので、数値の項目には数字だけを書きます）。`$HOME` などは展開されないので、`WINEPREFIX` は絶対パスで書きます。受け付ける形の詳細は [docs/config.md](docs/config.md#宣言形式134) にあります。
* この形に合わない行が 1 行でもあると、ファイル全体がこれまでどおりの読み方になります (一部の行だけが新しい読み方になることはありません)。書き換えたら `./doctor.sh` の `config` の行で確かめてください。


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
* 前の回がまだ終わっていないときは、その分は何もしないで終わります(重なって動きません)。前の回が約 23 分(既定の `ATST_CHECK_TIMEOUT=40` で 1375 秒。`ATST_CHECK_TIMEOUT` に応じて変わります)以上終わらないと、「毎分の監視 (check_all.sh) が ... 止まっています」(RUNNER_STUCK)と LINE に通知します。
* MetaTrader のプロセス停止(PROCESS)・監視データの停止(MONITORING)・ティック途絶(TICK)・取引できない状態(TRADE)・毎分の監視の停止(RUNNER_STUCK)が続いているときは、【発生】の通知から 30 分 / 2 時間 / 12 時間後に「【継続中 30 分】MetaTraderプロセスが動作していません: ...」のように 1 回ずつ再通知します(1 件の異常につき最大 3 通。その回の他の通知と同じ 1 通に入ります。12 時間の後は復帰するまで送りません)。値動き・スプレッド・Ping などの異常は再通知しません。
    * 間隔は `~/.atst/config` の `ATST_ALERT_REMIND_MINUTES="30 120 720"`(空白区切りの分、昇順、1〜3 個)で変えられます。`""` にすると再通知しません。行が無いとき・値が正しくないときは `30 120 720` で動きます(値が正しくないときは、対象のキーで異常が続いている間、毎分 `check_all.log` に対象キーごとに 1 行残ります。異常が無いときは何も残りません)。
* ティック途絶(`check_tick.sh`): 監視 EA の CSV の列 2(最後のティックの時刻)が `ATST_TICK_THRESHOLD` 秒(既定 600)変わらないと「価格データ（ティック）が ... 分以上更新されていません」と通知します(ブローカーとの接続断・ログアウト・銘柄の配信停止など。MetaTrader も監視 EA も動いているのに取引できない状態)。CSV 自体が止まっているときは監視データの停止(MONITORING)だけを通知します。UTC の金曜 20:00〜月曜 00:00 と、MetaTrader・監視 EA の再開直後(CSV が `ATST_MONITORING_THRESHOLD` 秒以上止まった後、`ATST_TICK_THRESHOLD` 秒分の行がたまるまで)は判定しません(週末は `ATST_TICK_WEEKEND_SKIP=0` で判定します)。祝日・早期クローズでは誤検知することがあります。`ATST_MONITORING_THRESHOLD` を `ATST_TICK_THRESHOLD` 以上にすると再開直後に誤検知することがあるので、前者を小さくしてください。監視 EA はティックの多い主要通貨ペアのチャートに載せてください。
* 取引できない状態(`check_trade_ready.sh`、#158): 監視 EA の CSV の列 9〜12(ブローカーへの接続・端末の自動売買ボタン・口座の取引許可・口座の EA 取引許可)が `ATST_TRADE_READY_THRESHOLD` 秒(既定 300)の間ずっと不良なら「… が 5 分以上取引できない状態です: 端末の自動売買ボタンが OFF です。…」のように理由を付けて通知し(キー `TRADE_<MT名>`)、すべて良好に戻ると【復帰】を送ります。MetaTrader も監視 EA も動いて CSV も更新されているのに自動売買が動かない状態を拾います。取引 EA 自身の「自動売買を許可」(EA のプロパティ)は見えません。判定しないのは、CSV の停止(MONITORING が通知)・UTC の金曜 20:00〜月曜 00:00(`ATST_TRADE_READY_WEEKEND_SKIP=0` で判定します)・MetaTrader や監視 EA の再開直後(`ATST_MONITORING_THRESHOLD` 秒以上の空白の後、`ATST_TRADE_READY_THRESHOLD` 秒分の行がたまるまで)・古い監視 EA(8 列の CSV)のときです。接続断ではティック途絶(TICK)と両方が届くことがあります。自動売買ボタンを意図して長期間 OFF にしている間も通知は届きます(無効にする設定はありません)。
    * 列 9〜14 は #158 で増えた列です。リポジトリの監視 EA を更新したら、`setup_monitoring_ea.sh` で `Experts` にコピーし、チャートに載せ直してください(`mtctl.sh stop` → `start` で自動配置が効いていれば載り直ります。そうでなければ VNC でチャートから外して付け直します)。載せ直すまでは `check_trade_ready.sh` は何もしません。`doctor.sh` の `csv` の行の `cols 14` で確かめられます。
* その回の通知(発生・復帰・再起動の検出・打ち切り)は、1 通にまとめて LINE に届きます(【ホスト名】は先頭に 1 つ、通知の間は空行です)。
    * 1 回目のチェック群が終わった時点で 1 通送ります。2 回目の約定のチェックやハートビートで打ち切りが出たときだけ、回の最後にもう 1 通届きます。
    * 通知は、従来より最大で 1 回目のチェック群の実行時間分(通常は数秒〜数十秒、打ち切りが重なると数分)遅れます。
    * 約定の通知と、「毎分の監視が止まっています」(RUNNER_STUCK)の通知は、まとめずにその場で個別に届きます。
    * まとめた通知が LINE の 1 メッセージの上限(5000 字)を超えるときは、通知の区切りで分けて送ります。
* 約定のチェックは 1 回目の開始から `ATST_ORDER_CHECK_INTERVAL` 秒(0〜50、既定 30。こちらも `~/.atst/config` の末尾に書きます)後にもう一度実行するので、従来どおり毎分 2 回です。
* ハートビート(`heartbeat.sh`)は `check_all.sh` の最後に送ります。外部サービス側の猶予(grace)は **3 分以上**を推奨します。
    * URL は `setup_heartbeat.sh` で設定します(`~/.atst/.heartbeat_url` に 600 で保存し、テストの ping を 1 回送ります。何も入力せずに Enter で削除)。`~/.atst/config` の `ATST_HEARTBEAT_URL` に書いた従来の設定もそのまま使えます(`.heartbeat_url` があればそちらが優先)。未設定なら何も送りません。
    * 正常なら `<URL>` に ping、監視が異常を検知している間は毎分 `<URL>/fail` に送ります(本文は発生中のキー名だけ。建玉・口座・通知の文面・ホスト名は入れません)。「ping が途絶える」は cron / VPS / ネットワークの停止、「`/fail` が届く」は監視が異常を検知中、と区別できます。
    * `/fail` になるもの: MT4/5 の停止(PROCESS)、監視対象が見つからない(TARGET)、監視 EA の CSV の停止(MONITORING)、ティック途絶(TICK)、取引できない状態(TRADE)、毎分の監視自体の異常(RUNNER_STUCK / RUNNER_TARGETS_EMPTY / 打ち切り。ハートビート自身の打ち切りは除く)、LINE の送信失敗の連続(`~/.atst/line_error.log` の直近 60 分に `ATST_HEARTBEAT_LINE_FAIL_COUNT` 件。既定 3。LINE が直っても最大 60 分は `/fail` が続くことがあります)、LINE の今月の送信数が上限の 8 割以上(毎朝の `check_daily.sh` が記録し、8 割未満を観測するまで続きます)。
    * `/fail` にならないもの: 値動き・スプレッド・Ping(PRICE / SPREAD / PING)の異常。これらは LINE の通知だけです。
    * `/fail` を受け付けないサービスでは、異常の間は ping も送られないので「ping の途絶」として通知されます。
    * 外形監視が未設定のときは、毎朝の稼働OK(`check_daily.sh`)の最後に「外形監視: 未設定(推奨。setup_heartbeat.sh で設定)」の 1 行が付きます(この行のためだけには送りません)。
    * 旧形式の crontab の `heartbeat.sh` の行が残っていると、その行の ping が `/fail` を打ち消して up/down が往復することがあります(移行が終わったら消してください)。
    * 監視対象から外した MT4/5 の発生状態が残ると `/fail` が続きます。そのときは `~/.atst/alert_status` の該当するキー(`PROCESS_<名前>` など)の行を消してください。
* `check_all.sh` と各チェックの stderr (エラーや警告) は `~/.atst/log/check_all.log` に追記します。
    * 回の先頭に `===== START 日時 pid=... =====` の 1 行が入ります。チェックが 0 以外で終わった回は `check_ping.sh: exit 3` のような 1 行 (打ち切りは `exit 124` / `exit 137`)、前の回が終わっていなくて飛ばした回は `another run holds the lock (started ... s ago); skipped` の 1 行が入ります。`START` の直後に `skipped` が続く 2 行は、飛ばした回です。
    * ディレクトリは 700、ファイルは 600 で作ります (既にあれば権限は変えません。`~/.atst` がまだ無い初回は、これも 700 で作ります)。2 MB を超えると、毎朝 6:30 の `truncate_monitoring.sh` が末尾 1 MB に切り詰めます。
    * 手で `check_all.sh` を実行したときも、stderr は端末に出ずにこのログに入ります (stdout は従来どおり)。
    * 「通知が来ない」「止まっています」「打ち切りました」が続くときは、まず `tail ~/.atst/log/check_all.log` を見てください。
    * ログを作れない・書けないときは従来どおり stderr は捨てられ、監視は止まりません。


### デスクトップ画像の通知の移行

朝の定期レポート (`report_image.sh`) のデスクトップ画像は、口座番号・残高が写るため、既定で送らなくなりました。画像の置き場所は ImgBB だけになり、ImgBB の API キー (`setup_imgbb.sh`) が無いときは画像を送らず、文字要約だけを送ります。

これまでどおりデスクトップ画像を受け取るには、`setup_imgbb.sh` で API キーを設定したうえで、`~/.atst/config` に次の 1 行を書きます。
```
ATST_IMAGE_REPORT_DESKTOP=1
```

* この行が無い `~/.atst/config` では、`check_daily.sh` が LINE で 1 度だけ案内します。上の 1 行を書くと案内は届きません。
* 画像が消えるまでの時間 (`ATST_IMGBB_EXPIRATION`) の既定は、7 日から 24 時間になりました。この行を `~/.atst/config` に書いてある場合は、その値のままです。

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

`~/.atst/config` が `ATST_AUTO_ATTACH_EA=1` のとき、`start` は StartUp ini を付けて起動します。MT4 は ini のパスを素の引数 (`terminal.exe C:\atst\startup_<名前>.ini`)、MT5 は `/config:C:\atst\startup_<名前>.ini` で渡します (下の「監視 EA の自動配置」)。通貨ペア・時間足の値が空・不正なときや ini を書けないときは、stderr に 1 行出して ini を付けずに起動します (起動は止めません)。

### 監視 EA の自動配置 (ATST_AUTO_ATTACH_EA、試験導入)

監視 EA (TerminalMonitoring) のチャートへの配置は、これまで VNC での手作業でした。`~/.atst/config` で有効にすると、`mtctl.sh start` (再起動時の `@reboot` の自動起動を含む) が MetaTrader の起動設定ファイル (StartUp ini) を作り、起動時に EA を新しいチャートに載せます。既定は無効 (`0`) です。

* 有効にする: `~/.atst/config` に次の 3 行を書き (雛形にあります。行が無い古い config は `0` と同じ)、次の `mtctl.sh start` から効きます。動いている MT4/5 には `mtctl.sh stop` → `start` が要ります (本番では止めてよい時間に)。手で `start` するときは `ATST_TARGETS` と同じ名前を使ってください (ini の名前は start に渡した名前から作ります)。
  ```
  ATST_AUTO_ATTACH_EA=1
  ATST_AUTO_ATTACH_SYMBOL=EURUSD   # ブローカーの気配値表示にある名前。英数字と . _ # & ! @ - (32 文字まで)
  ATST_AUTO_ATTACH_PERIOD=M5       # M1 M5 M15 M30 H1 H4 D1 W1 MN のどれか
  ```
* ini の場所と内容: `$WINEPREFIX/drive_c/atst/startup_<名前を小文字にして英数字と _ 以外を _ にしたもの>.ini` (MT4/5 から見て `C:\atst\startup_<名前>.ini`。ディレクトリ 700・ファイル 600)。Z: ドライブを使わないので、Z: を外した prefix でも動きます。中身はコメント 1 行と `[StartUp]` の `Symbol=` / `Period=` / `Expert=` (MT5 は `Advisors\TerminalMonitoring`) だけで、`[Common]` (口座番号・パスワード)・`[Experts]` は書きません。起動のたびに同じ内容で上書きします。
* 渡し方: MT4 は ini のパスを素の引数で渡します (`terminal.exe C:\atst\startup_<名前>.ini`)。MT4 は `/config:<パス>` を無視するためです (実機で確認)。MT5 は MetaQuotes の仕様どおり `/config:C:\atst\startup_<名前>.ini` で渡します。`~/.atst/wine_<名前>.log` の `auto_attach:` 行に、渡した引数がそのまま残ります。
* 戻し方: `ATST_AUTO_ATTACH_EA=0` にして `mtctl.sh stop` → `start` すると、ini を付けない今までの起動に戻ります。ini を消しても `1` のままなら次の `start` で作り直すので、切り替えは変数で行ってください。
* 通知: 有効なのに、MT4/5 が起動してから `ATST_MONITORING_THRESHOLD` 秒たっても起動後のモニタリングデータが出ていなければ、キー `MONITORING_AUTO_ATTACH_<MT名>` で【発生】を送ります (既存の `MONITORING_<MT名>` とは別のキー。データが出れば【復帰】、`0` に戻したときも【復帰】で閉じます)。再通知・外形監視 (heartbeat) の対象にもなります (`MONITORING_` で始まるキーのため)。確認先は ini、`~/.atst/wine_<名前>.log` の `auto_attach:` 行、`doctor.sh` の `auto_attach`。
* 名前の注意: `A-MT4` と `A_MT4` のように、小文字化・置換した後に同じ名前になる MT を同時に使うと、同じ ini を共有して衝突します。そのような名前は避けてください。
* 実機での確認結果 (MT4 build 1492 / Wine 10.0、デモ口座):
  * ini のパスを素の引数で渡すと `[StartUp]` が効き、指定した通貨ペア・時間足の新しいチャートに監視 EA が載りました。CRLF と先頭のコメント行は問題ありません。ディレクトリ 700・ファイル 600 でも MT4 は読めます (同じユーザーで動くため)。
  * `/config:<パス>` で渡すと MT4 は ini を無視しました (チャートが開かない)。そのため MT4 は素の引数で渡します。
  * StartUp で開いたチャートはプロファイルに保存されないので、再起動を繰り返してもチャートは増えません。
  * 手で置いた監視 EA のチャートがあると、それとは別に StartUp のチャートが開き、EA が 2 つ載ります (両方が同じ CSV に書きます)。自動配置にしたら、手で置いた監視 EA のチャートは閉じてかまいません。同じ通貨ペア・時間足のチャートが既にあるときの挙動は未確認です。
  * `mtctl.sh status` と `doctor.sh` の `process` は、ini の引数付きで動いている MT4 を正しく見つけます。
  * MT5 (`/config:`) は実機で未確認です。`MN` の表記も未確認です。

### 自己診断 (doctor.sh)

`./doctor.sh` (引数なし) で、atst の設定と監視の状態を項目ごとに 1 行で表示します。**読み取り専用**で、ファイル・crontab・MT4/5・Wine を一切変更せず、LINE への送信やネットワークアクセスもしません (`wine --version` と `crontab -l` を実行するだけです。`~/.atst/config` が無い初回だけは、共通処理が雛形を作ります)。

各行は `OK` / `NG` / `--` で始まります。`--` は「未設定・対象なし・表示のみ (判定しない)」です。補足の行は空白 2 個で字下げして表示し、最終行は件数のまとめです。NG が 1 件以上あれば終了コード 1、無ければ 0 です (`--` は終了コードに影響しません)。引数を付けると使い方を表示して終了コード 1 で終わります。

見る項目:
1. `wine --version`: wine が PATH にあり、版を表示できるか。
2. `arch`: 使用中の WINEPREFIX (config 読み込み後) があり、`system.reg` の `#arch=` の値。
3. `WINEPREFIX`: 対話シェルの環境変数 (`env=`)、config 読み込み後 (`config=`)、環境変数を外して config を読んだ値 (`cron=`、cron で使われる値) を並べ、`config=` と `cron=` が違えば NG (文字列で比較するので、シンボリックリンク経由で同じ場所を指していても NG になります)。
   - `config`: `~/.atst/config` が KEY=VALUE 形式 (`OK config KEY=VALUE 形式 ...`) か旧形式 (`OK config 旧形式 ... N 行目 (KEY) ...`) か。旧形式も NG にはしません。値は表示しません。
4. `target` / `mt`: `ATST_TARGETS` の各名前が検出した MT4/5 に前方一致するか (未設定・空は NG)。どの名前にも選ばれない MT4/5 は `--` (監視対象外) で表示します。前方一致で複数に当たるときは、check_*.sh と同じく最初の 1 つだけが監視対象です。
5. `process`: 対象の MT4/5 が起動しているか。
6. `ea` / `csv`: 監視 EA (`TerminalMonitoring.ex4` / `.ex5`) が置かれているか、`terminal_monitoring.csv` の最終行が `ATST_MONITORING_THRESHOLD` 秒より新しいか (check_monitoring.sh と同じ基準)。`csv` の行の末尾の `cols N` は最終行の列数で、14 未満なら古い監視 EA のままなので、「the monitoring EA is old (N fields) …」の補足行を出します (判定は変えません。監視 EA を更新して載せ直すと 14 になり、`check_trade_ready.sh` が働きます)。CSV の各列の意味は [docs/monitoring-csv.md](docs/monitoring-csv.md) を参照してください。
7. `crontab -l`: 新形式 (`check_all.sh`) なら OK、旧形式 (`wrapper.sh`) のみなら OK で「旧形式」と添えます。両方ある (混在)・どちらも無いときは NG。
8. `line_error.log`: `~/.atst/line_error.log` の LINE 送信失敗の見出し行 (末尾 5 件)。表示のみです。
9. `.line_token` / `.line_id` / `.imgbb_key`: 存在と権限 (600 でなければ NG)。`.imgbb_key` は任意です (定期レポートにグラフ・デスクトップの画像を付けるのに必要。無ければ文字要約だけを送ります)。
10. `heartbeat`: 外形監視の URL。`~/.atst/.heartbeat_url` (setup_heartbeat.sh) が有効なら `OK heartbeat .heartbeat_url=****abcd`、config の `ATST_HEARTBEAT_URL` なら `OK heartbeat ATST_HEARTBEAT_URL=****abcd` (末尾 4 文字のみ)。`.heartbeat_url` が 600 でなければ NG。未設定は `-- heartbeat not set (recommended: run setup_heartbeat.sh)` (推奨ですが必須ではないので NG にはしません)。疎通確認はしません。
11. `check_all.log`: `~/.atst/log/check_all.log` の権限・最後の START 行の日時・START 行以外の末尾 5 行。表示のみです (権限が 600 でなくても NG にしません)。**末尾の行は各チェックの出力そのままなので、Issue に貼る前に目で確認してください。**
12. `auto_attach`: 監視 EA の自動配置。`ATST_AUTO_ATTACH_EA` が `1` でなければ `-- auto_attach <名前> ATST_AUTO_ATTACH_EA=0 (manual attach)`。`1` なら、通貨ペア・時間足の値、`C:\atst\startup_<名前>.ini` (`$WINEPREFIX/drive_c/atst/`) の有無・権限 (ディレクトリ 700・ファイル 600)・config との一致、動いている MT4/5 にその ini の引数が渡っているか (MT4 は `C:\atst\startup_<名前>.ini`、MT5 は `/config:C:\atst\startup_<名前>.ini`)、を見て、外れていれば NG (MT4 が `/config:` 付きで動いていれば `running with /config:, which MT4 ignores` で NG。`mtctl.sh stop` → `start` で直ります)。OK でも `csv` が NG なら「StartUp が効いていない可能性」の補足行を出します。

NG の例:
```
NG WINEPREFIX env=~/.wine32 config=~/.wine32 cron=~/.wine
  interactive shell and cron use different WINEPREFIX; set WINEPREFIX in ~/.atst/config
NG crontab -l mixed: both check_all.sh and wrapper.sh
NG .line_token mode 644 (must be 600): ~/.atst/.line_token
```

トークン・キー・URL は末尾 4 文字だけ (`****abcd`) を表示し、LINE ID は表示しません。ホームディレクトリは `~` で表示するので、出力はそのまま Issue に貼れます (貼る前に念のため目で確認してください)。

### スマホからの日常確認 (doctor.sh / snap.sh)

状態と画面を見るだけなら、スマートフォンの ssh クライアント (Termius など) から次のコマンドで足ります。VNC を開くのは、手動決済など操作が必要なときだけにしてください (見るだけのつもりで VNC を開き、クリック位置のずれで MT を閉じてしまう事故を避けるためです)。

* 状態: `doctor.sh` で全体を ([自己診断](#自己診断-doctorsh))、`mtctl.sh status <name>` で MT ごとの稼働を、`mtctl.sh -s list` で検出した MT の一覧を見ます。どれも読み取りだけです。
* 画面: `snap.sh` (引数なし) で VNC のデスクトップ (:1) を 1 枚撮り、`~/.atst/snap/<年月日-時分秒>.jpg` に保存して、そのファイルの絶対パスだけを 1 行出力します (ディレクトリは 700、ファイルは 600。画像には口座番号・残高が写ります)。
  * `~/.atst/config` の `ATST_SNAP_KEEP` (1〜1000、既定 10。行が無い古い config も 10) 枚を残し、古いものから消します。消すのは `~/.atst/snap/` 直下の日時の名前の jpg だけです。1 枚は数十〜100 KB 程度です。
  * `snap.sh --line` は、撮った画像を ImgBB 経由で LINE にも送ります。ImgBB の API キー (`setup_imgbb.sh`) が無いときは撮らずに終わります。画像は URL を知っていれば誰でも見られ、`ATST_IMGBB_EXPIRATION` 秒で消えます。定期レポートの `ATST_IMAGE_REPORT_DESKTOP` とは関係なく、`--line` を付けたときだけ送ります。
  * `[error]` は stderr に出ます。`vncsnapshot not found` (パッケージが無い)、`~/.vnc/passwd` が読めない、ImgBB のキーが無い (`--line` のとき)、`vncsnapshot failed` (VNC サーバーが止まっているなど) のどれかです。終了コードは 0 (成功)、1 (引数の誤り)、2 (失敗。`--line` で LINE への送信だけ失敗したときは、画像は残してパスも出します)。
* スマートフォンからの取り方: ssh のコマンド実行ではリポジトリが `PATH` に無いので、ディレクトリ付きで呼びます (既定の展開先 `auto-trading-support-tools-master/` の例)。
  ```
  ssh <vps> '~/auto-trading-support-tools-master/snap.sh'
  scp "<vps>:$(ssh <vps> '~/auto-trading-support-tools-master/snap.sh')" .
  ```
  1 行目は撮ってパスを表示するだけ、2 行目は撮った画像を手元にコピーします。Termius などの SFTP で `~/.atst/snap/` を開き、いちばん新しいファイルを見る方法もあります。

### 困ったとき

LINE に異常の通知が届いたときの確認と復旧の手順は、通知ごとに [docs/RUNBOOK.md](docs/RUNBOOK.md) にまとめてあります。まず `./doctor.sh` を実行し、スマートフォンの MT アプリで建玉を確認してから、通知の種類の節を見てください。
