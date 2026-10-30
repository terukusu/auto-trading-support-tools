# 運用手順（atst）

LINE の通知を受けた人が、まず何を見て、どこまでやってよいか、直らないときどうするかを、通知ごとにまとめる。**読み取り専用の確認を先に、変える操作は後に**。**建玉が決済されないことが最悪の事態**なので、MT を止める・再起動する前には必ずスマホの MT アプリで建玉を見る。コマンドは atst のディレクトリ（通常は `~/auto-trading-support-tools-master`。違う場所に置いた場合は `crontab -l` の `PATH=` の先頭）で実行する。

- [最初の 3 手](#最初の-3-手)
- [安全の原則](#安全の原則)
- [通知ごとの確認・復旧手順](#通知ごとの確認復旧手順)
  - [REBOOT](#key-reboot) / [PROCESS_](#key-process) / [TARGET_](#key-target) / [MONITORING_](#key-monitoring) / [MONITORING_AUTO_ATTACH_](#key-monitoring-auto-attach) / [PING_](#key-ping) / [PRICE_](#key-price) / [SPREAD_](#key-spread) / [ORDER](#key-order)
  - [RUNNER_STUCK](#key-runner-stuck) / [RUNNER_TIMEOUT_](#key-runner-timeout) / [RUNNER_TARGETS_EMPTY](#key-runner-targets-empty)
  - [IMAGE_REPORT_DEFAULT_CHANGED](#key-image-report-default-changed) / [LINE_QUOTA](#key-line-quota) / [IMAGE_UPLOAD_FAILED](#key-image-upload-failed) / [HEARTBEAT](#key-heartbeat)
- [MT の固まりの切り分け](#mt-の固まりの切り分け)
- [VNC の既知の罠](#vnc-の既知の罠)
- [秘匿値の扱い](#秘匿値の扱い)

## 最初の 3 手

1. ssh で入り（スマホからは Wiki の [setup_mobile_ssh](../../../wiki/setup_mobile_ssh)）、atst のディレクトリで `./doctor.sh` を実行して出力を控える。
   ```bash
   cd ~/auto-trading-support-tools-master
   ./doctor.sh
   ```
   `doctor.sh` は読み取り専用で、何も変えない。ネットワークも LINE も使わないので、夜中に何度実行しても LINE の送信枠（無料プランは月 200 通）を使わない。`NG` の行がそのまま次に見る場所になる。出力はホームを `~`、トークン・キー・URL を末尾 4 文字で表示するので、Issue に貼ってよい（`check_all.log` の末尾の行だけは貼る前に目で見る。[秘匿値の扱い](#秘匿値の扱い)）。
2. MT の状態を、cron と同じ WINEPREFIX で確かめる。
   ```bash
   env -u WINEPREFIX ./mtctl.sh status "<MT 名>"
   ```
   出力は `status=running, pid=<pid>, name=<MT 名> (WINEPREFIX=...)` か `status=stopped, pid= -, name=<MT 名> (WINEPREFIX=...)`。**末尾の ` (WINEPREFIX=...)` が `doctor.sh` の `WINEPREFIX` 行の `cron=` と同じことを確かめてから `status=` を信じる**。`cron=` の値を明示して `WINEPREFIX=~/.wine ./mtctl.sh status "<MT 名>"` のように打ってもよい（`~/.wine` は config の既定。自分の `cron=` の値に置き換える）。**名前が合っていないときも `status=stopped` と表示される**（MT の停止と区別できない）ので、`stopped` と出たら、先に `./mtctl.sh list` の `name=` に `<MT 名>` が前方一致するか（または `./doctor.sh` の `target` 行が `OK` か）を確かめる。2026-10 に対話シェル（`~/.wine32`）と cron（`~/.wine`）の WINEPREFIX がずれていて、手で打った `mtctl.sh status` が `stopped` と誤答した（#132）。
3. スマホの MT アプリ（Wiki の [setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉・口座残高・接続状態を見る。建玉はブローカー側にあり、VPS の MT を止めても再起動しても消えない。ただし EA の決済ロジックは VPS の MT が動いている間しか働かない。

`<MT 名>` は `~/.atst/config` の `ATST_TARGETS` に書いた名前（`./mtctl.sh list` の `name=` の先頭部分）。`<data>` は `./mtctl.sh list` の各行の `data=` の値（MT のデータフォルダ）。MT5 はパスの `MQL4` を `MQL5` に読み替える。

通知の書き出しから節を引く早見表:

| 通知の書き出し（`【発生】` などの後ろ） | キー | 節 |
|---|---|---|
| サーバーの再起動を検出しました | （キー無し） | [REBOOT](#key-reboot) |
| MetaTraderプロセスが動作していません | `PROCESS_<MT名>` | [PROCESS_](#key-process) |
| 監視対象のMetaTraderが見つかりません | `TARGET_<名前>` | [TARGET_](#key-target) |
| `<MT 名>` のモニタリングデータが … 更新されていません／ありません | `MONITORING_<MT名>` | [MONITORING_](#key-monitoring) |
| `<MT 名>` の自動配置 (ATST_AUTO_ATTACH_EA=1) が有効ですが … モニタリングデータが出ていません | `MONITORING_AUTO_ATTACH_<MT名>` | [MONITORING_AUTO_ATTACH_](#key-monitoring-auto-attach) |
| `<MT 名>` のPingが … 異常値 | `PING_<MT名>` | [PING_](#key-ping) |
| `<MT 名>` の過去10分の値幅が … 異常値 | `PRICE_<MT名>` | [PRICE_](#key-price) |
| `<MT 名>` の5分間のスプレッド最高値が … 異常値 | `SPREAD_<MT名>` | [SPREAD_](#key-spread) |
| 約定の内容（EA が書いた行）／約定通知 (N 行) を LINE が受け付けませんでした | （キー無し） | [ORDER](#key-order) |
| 毎分の監視 (check_all.sh) が、前回の実行が終わらないため … 止まっています | `RUNNER_STUCK` | [RUNNER_STUCK](#key-runner-stuck) |
| チェックが … 秒で終わらず打ち切りました | `RUNNER_TIMEOUT_<名前>` | [RUNNER_TIMEOUT_](#key-runner-timeout) |
| 監視対象が設定されていません | `RUNNER_TARGETS_EMPTY` | [RUNNER_TARGETS_EMPTY](#key-runner-targets-empty) |
| 【お知らせ】デスクトップ画像の通知は既定 OFF になりました | `IMAGE_REPORT_DEFAULT_CHANGED` | [IMAGE_REPORT_DEFAULT_CHANGED](#key-image-report-default-changed) |
| 【注意】LINE の今月の送信数が上限の8割を超えました | `LINE_QUOTA` | [LINE_QUOTA](#key-line-quota) |
| 本文の末尾に (画像アップロード失敗: N枚) | （キー無し） | [IMAGE_UPLOAD_FAILED](#key-image-upload-failed) |
| 外部サービス（Healthchecks.io など）からのメール等 | （外部サービス側） | [HEARTBEAT](#key-heartbeat) |

`【継続中 30 分】` / `【継続中 2 時間】` / `【継続中 12 時間】` で始まる通知は、同じ文面の `【発生】` と同じ節を見る。

## 安全の原則

- 読み取り専用のコマンド（`./doctor.sh` / `./mtctl.sh status` / `./mtctl.sh list` / `ls` / `tail` / `cat` / `grep`）を先に、変えるコマンド（`./mtctl.sh stop` / `start`、`kill`、VNC での操作、`~/.atst/config` の編集）を後に。
- MT を止める前に行うこと:
  - (a) スマホの MT アプリで建玉を確認する。
  - (b) `env -u WINEPREFIX ./mtctl.sh status "<MT 名>"` で止める対象の pid と名前を確認する（別の MT を止めない）。名前は `./mtctl.sh list` の `name=` に前方一致することを確かめる（合っていない名前でも `status=stopped` と出る）。
  - (c) 建玉があり EA が決済を担っているなら、止めている間はスマホで価格を見ておく（決済が必要なら手動決済）。
- 止めるのは 1 つずつ。**`./mtctl.sh stop` は TERM を 1 回送るだけで、終了を待たない**。`status` が `stopped` になるまで数秒おきに確かめてから `start` する。残るときは pid を `status` で確かめ直してから `kill -KILL <pid>`。
- **`./mtctl.sh start` は起動済みかを確かめない（二重起動を防がない）**。必ず先に `status` で `stopped` を確かめる。
- `kill` するのは、pid を `./mtctl.sh status` や `ps -o pid,cmd -p <pid>` で確かめたものだけ。`pkill` / `killall` / `wineserver -k` は使わない（他の MT も巻き込む）。
- `check_all.sh` や `check_*.sh` を手で実行しない（LINE に送り、状態を書き換える）。状態の確認は `./doctor.sh` で足りる。
- `~/.atst/alert_status` を手で消さない・編集しない（同じ通知がもう一度届き、送信枠を使う）。例外は README「毎分の監視 (check_all.sh) の動き」にある、監視対象から外した MT のキーの行を消す場合だけ。
- 手順の練習や検証は、使い捨ての VPS か MT 非稼働・建玉なしの検証機で行い、稼働中の本番 VPS では試さない（CLAUDE.md「実行・検証」と同じ）。
- `sudo` が要る操作（apt、VPS の再起動、サービスの操作）は RUNBOOK の範囲外。必要になったら朝まで待つか、別途判断する。
- 朝まで待ってよい条件（全節で共通）: 建玉が無い、または建玉はあるが EA の決済を待たなくてよい（スマホで損益を許容できる、または手動決済した）。建玉があり EA の決済に任せている間に MT が止まっている・固まっているなら待たない。

## 通知ごとの確認・復旧手順

共通の事項:

- LINE の本文の先頭には `【<ホスト名>】` が付く（以下の通知文の例では省く）。毎分の監視（`check_all.sh`）の 1 回分の通知は 1 通にまとめて届く（通知の間は空行）。約定通知と `RUNNER_STUCK` の発生は、まとめずに個別に届く。
- 状態付きのキーは `~/.atst/alert_status` に 1 行ずつ記録される（`キー,値,時刻(epoch)`、再通知を送った後は 4 列目に段階。値 1 = 発生中、0 = 復帰済み）。発生と復帰はそれぞれ 1 回だけ届き、送れなかった回は次の回に送り直す。発生中のキーの一覧は次で見る。
  ```bash
  grep ',1,' ~/.atst/alert_status
  ```
- MT 名付きのキー（`PROCESS_` / `MONITORING_` / `PING_` / `PRICE_` / `SPREAD_`）の `<MT名>` は、`./mtctl.sh list` の `name=`（フォルダ名）の空白を `_` にしたもの（例: `PROCESS_Land_Prime_MetaTrader_4_Terminal`）。通知文の中の名前は `ATST_TARGETS` に書いた名前。
- しきい値は発生と復帰で別（発生は `..._UPPER` 以上、復帰は `..._LOWER` 以下。間にいる間は状態を変えない）。設定は `~/.atst/config`。`ATST_TARGETS` / `ATST_CHECK_TIMEOUT` / `ATST_ORDER_CHECK_INTERVAL` は config の末尾に置く（書き間違えた行より後は読まれないため）。
- 継続中の通知（#141）: `PROCESS_*` / `MONITORING_*` / `RUNNER_STUCK` は、発生したまま直らないと、発生の通知から 30 分 / 2 時間 / 12 時間後に `【継続中 30 分】` / `【継続中 2 時間】` / `【継続中 12 時間】` の書き出しで同じ文面が 1 回ずつ届く（1 件の異常につき最大 3 通。送れずに遅れたときは、その時点で達した最も先の段階の 1 通だけが届く。12 時間の後は復帰まで届かない）。間隔は `~/.atst/config` の `ATST_ALERT_REMIND_MINUTES`（既定 `"30 120 720"` 分、`""` で届かない）。値動き・スプレッド・Ping などは継続中の通知が無い。
- 外形監視（#136）: 発生中のキーのうち `PROCESS_` / `TARGET_` / `MONITORING_` / `RUNNER_`（`RUNNER_TIMEOUT_HEARTBEAT` を除く）/ `LINE_QUOTA` があると、`heartbeat.sh` が外部サービスへ毎分 ping の代わりに `/fail` を送る（[HEARTBEAT](#key-heartbeat)）。
- 毎分の監視の stderr（エラー・警告）は `~/.atst/log/check_all.log` に残る（#144）。回の先頭に `===== START <日時> pid=<pid> =====` の行、チェックが 0 以外で終わった回は `check_ping.sh: exit 3` のような行（打ち切りは `exit 124` / `exit 137`）、前の回が終わらず飛ばした回は `another run holds the lock (started ... s ago); skipped` の行が入る。
  ```bash
  tail -n 50 ~/.atst/log/check_all.log
  ```

<a id="key-reboot"></a>

### REBOOT（キー無し）: サーバーの再起動を検出した

**キー名**: 無し（`alert_status` に記録しない。復帰の通知も無い）。

**通知文の例**: `サーバーの再起動を検出しました。再起動日時: <日時>`

**意味**: `check_reboot.sh` が、`/proc/uptime` の秒数が前回の記録（`~/.atst/uptime`）より小さくなったのを見て出す。再起動のあとは cron の `@reboot` の行（`run_with_targets.sh mtctl.sh start`）が `ATST_TARGETS` の MT を起動する。

**確認コマンド**:
```bash
uptime
crontab -l
./doctor.sh
env -u WINEPREFIX ./mtctl.sh status "<MT 名>"
```
`crontab -l` に `@reboot    run_with_targets.sh mtctl.sh start` の行があるか、`doctor.sh` の `process` / `csv` 行が `OK` かを見る。そのあと VNC で MT の窓・口座の接続・「自動売買」ボタン・チャートの EA を見る。

**安全な復旧手順**:
1. `status=stopped` なら [PROCESS_](#key-process) の手順で起動する。
2. `status=running` なのに CSV の更新が止まる（`MONITORING_` が来る）なら [MT の固まりの切り分け](#mt-の固まりの切り分け)へ。`@reboot` の直後にも MT の UI が固まった実例がある。
3. 再起動の原因の調査（VPS 事業者側・`sudo` が要るもの）は範囲外。

**それでも直らないとき**: スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を確認し、必要なら手動決済する。朝まで待ってよい条件は [安全の原則](#安全の原則) の最後の項。

**関連**: [README](../README.md)「既存の crontab からの移行」（`@reboot` の行）、Wiki [setup_monitoring](../../../wiki/setup_monitoring)。

<a id="key-process"></a>

### PROCESS_<MT名>: MetaTrader のプロセスが無い

**キー名**: `PROCESS_<MT名>`（例: `PROCESS_Land_Prime_MetaTrader_4_Terminal`）。

**通知文の例**:
- `【発生】MetaTraderプロセスが動作していません: <MT 名>`
- `【継続中 30 分】MetaTraderプロセスが動作していません: <MT 名>`（30 分 / 2 時間 / 12 時間後）
- `【復帰】MetaTraderプロセスが再開しました: <MT 名>`

**意味**: `check_process.sh` が毎分、自分のユーザーの `terminal.exe` のうち、WINEPREFIX が自分と同じものを `/proc` から探して、見つからないと出す。MT が落ちた・VNC で窓を閉じた、のほか、**WINEPREFIX がずれていると MT が居ても「無い」と判定される**。

**確認コマンド**:
```bash
./doctor.sh
env -u WINEPREFIX ./mtctl.sh status "<MT 名>"
ls -l ~/.atst/wine_*.log
tail -n 30 ~/.atst/wine_*.log
```
`doctor.sh` の `process` 行（`NG process <名前> not running`）と `WINEPREFIX` 行（`NG` なら `config=` と `cron=` がずれている）を見る。`wine_*.log` は `mtctl.sh start` が Wine の出力を追記するログ（起動ごとに `===== START <日時> =====` の行）。

**安全な復旧手順**:
1. `status` が `stopped` であることを確かめる（`start` は二重起動を防がない）。名前の打ち間違いでも `stopped` と出るので、`./doctor.sh` の `target` 行が `OK`（または `./mtctl.sh list` の `name=` に前方一致）であることも確かめる。`doctor.sh` の `WINEPREFIX` 行が `NG` なら起動せず、先に `~/.atst/config` の `WINEPREFIX` を直す（MT が別の prefix で動いている可能性がある）。
2. スマホの MT アプリで建玉を確認する。
3. 起動する。
   ```bash
   env -u WINEPREFIX ./mtctl.sh start "<MT 名>"
   env -u WINEPREFIX ./mtctl.sh status "<MT 名>"
   ```
   `./mtctl.sh start` は起動済みかを確かめずに起動するので、起動は必ず `stopped` を確かめた 1 台ずつ、名前を指定して行う。cron の `@reboot` と同じ `run_with_targets.sh mtctl.sh start`（`ATST_TARGETS` の全部を起動する）は、稼働中の MT を二重に起動するので手では使わない。
4. VNC で口座の接続・「自動売買」ボタン・チャートの EA を確かめる。
5. 1〜2 分で `【復帰】` が届くのを待つ。

**それでも直らないとき**: 起動しても落ちるなら `wine_*.log` の末尾を Issue に貼って相談する（口座番号などが写っていないか目で見てから）。その間はスマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見て、必要なら手動決済する。MT が止まっている間は EA の決済が動かないので、建玉があるなら朝まで待たない。

**関連**: [README](../README.md) の `mtctl.sh` の使い方と「自己診断 (doctor.sh)」、#132（WINEPREFIX の表示と `doctor.sh`）、#141（継続中の通知）。

<a id="key-target"></a>

### TARGET_<名前>: 監視対象の MetaTrader が見つからない

**キー名**: `TARGET_<名前>`（`<名前>` は `ATST_TARGETS` に書いた名前の英数字と `_` 以外を `_` にしたもの）。

**通知文の例**:
- `【発生】監視対象のMetaTraderが見つかりません。監視と自動起動が無効になっています。~/.atst/config の ATST_TARGETS (旧形式の crontab では TARGET) とインストール先のフォルダ名を確認してください: <名前>`
- `【復帰】監視対象のMetaTraderが見つかりました: <名前>`

**意味**: `check_process.sh` が、`ATST_TARGETS` の名前に前方一致する MT のフォルダ（大文字小文字は区別しない。正規表現ではなく文字どおり）を見つけられないと出す。**この間、その名前の監視（プロセス・監視データ・Ping・値動き・スプレッド）・約定通知・再起動時の自動起動はすべて止まっている**。

**確認コマンド**:
```bash
./mtctl.sh list
./doctor.sh
grep -n '^ATST_TARGETS' ~/.atst/config
bash -n ~/.atst/config
```
`list` の 1 行目の `(WINEPREFIX=...)` が `doctor.sh` の `cron=` と違うと、別の prefix の MT は見えない。`doctor.sh` の `target` 行（`NG target <名前> no MetaTrader matches`）と、`-- mt ... not in ATST_TARGETS` の行（どの名前にも選ばれていない MT）を見る。

**安全な復旧手順**:
1. `~/.atst/config` の末尾の `ATST_TARGETS=(...)` の名前を、`./mtctl.sh list` の `name=` の先頭部分に合わせて直す（例: フォルダ名 `Land Prime MetaTrader 4 Terminal` なら `'Land Prime'`。名前に `'` を含むなら `"` で囲む）。
2. `bash -n ~/.atst/config` で何も表示されないことを確かめる。
3. `./doctor.sh` の `target` 行が `OK` になり、次の分に `【復帰】` が届くのを待つ。止まっていた間に MT が落ちていないか `env -u WINEPREFIX ./mtctl.sh status "<MT 名>"` でも見る。

**それでも直らないとき**: スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見る。この間は監視が効いていないので、建玉があるなら朝まで待たずに直すか、スマホで見張る。

**関連**: [README](../README.md)「監視するMT4/5の指定 (ATST_TARGETS)」。

<a id="key-monitoring"></a>

### MONITORING_<MT名>: 監視データが更新されない／無い

**キー名**: `MONITORING_<MT名>`。

**通知文の例**:
- `【発生】<MT 名> のモニタリングデータが <N> 分以上の間更新されていません。 EAが動いていない可能性が有ります。`（既定は 3 分）
- `【発生】<MT 名> のモニタリングデータがありません。TerminalMonitoring EA がチャートに設定されていない可能性が有ります。フリーズ・Ping・スプレッド・値動きの監視が効いていません。データファイル: <data>/MQL4/Files/terminal_monitoring.csv`
- `【継続中 30 分】<MT 名> のモニタリングデータが <N> 分以上の間更新されていません。 EAが動いていない可能性が有ります。`（30 分 / 2 時間 / 12 時間後。「ありません」の側も同じく `【継続中 …】` で届く）
- `【復帰】<MT 名> のモニタリングデータの更新が再開しました。`

**意味**: `check_monitoring.sh` が、監視 EA（TerminalMonitoring）の CSV の最後の行の時刻（1 列目、UTC の epoch 秒）が `ATST_MONITORING_THRESHOLD` 秒（既定 180）より古いと出す。「更新されていません」は **MT の固まり**か EA がチャートから外れた、「ありません」は EA がチャートに置かれていない。MT のプロセスは居るので `PROCESS_` は出ない（MT が止まっているときは `PROCESS_` の担当で、こちらは出ない）。CSV の列の意味は [docs/monitoring-csv.md](monitoring-csv.md)。

**確認コマンド**:
```bash
./doctor.sh
ls -l "<data>/MQL4/Files/terminal_monitoring.csv"
tail -n 3 "<data>/MQL4/Files/terminal_monitoring.csv"
env -u WINEPREFIX ./mtctl.sh monitor "<MT 名>"
```
`doctor.sh` の `ea` 行（EA ファイルがあるか）と `csv` 行（`last update <N>s ago (threshold <N>s)` / `not found` / `no data line`）を見る。`monitor` は CSV を `tail -f` で流す（Ctrl+C で止める）。

**安全な復旧手順**:
- 「ありません」（`ea` が `NG`、または `csv` が `not found` / `no data line`）: `./setup_monitoring_ea.sh` で EA を置き（全 MT に置く。引数なし）、VNC で MT のナビゲータ（Ctrl+N）の「エキスパートアドバイザ」から `TerminalMonitoring` をチャートへドラッグし、自動売買を許可する（設定は Wiki [setup_monitoring](../../../wiki/setup_monitoring)）。
- 「更新されていません」: [MT の固まりの切り分け](#mt-の固まりの切り分け)へ。固まっていなければ、VNC でチャートに EA が付いているか（チャート右上のアイコン）と「自動売買」ボタンを見る。

**それでも直らないとき**: MT の再インストールはせず、`./doctor.sh` の出力を Issue に貼って相談する。その間はスマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見て、必要なら手動決済する。固まっている MT では EA の決済も動かないので、建玉があるなら朝まで待たない。

**関連**: [docs/monitoring-csv.md](monitoring-csv.md)、[README](../README.md)「毎分の監視 (check_all.sh) の動き」、Wiki [setup_monitoring](../../../wiki/setup_monitoring)、#141（継続中の通知）、#149（CSV の列契約）。

<a id="key-monitoring-auto-attach"></a>

### MONITORING_AUTO_ATTACH_<MT名>: 自動配置したのに監視データが出ない

**キー名**: `MONITORING_AUTO_ATTACH_<MT名>`（`~/.atst/config` が `ATST_AUTO_ATTACH_EA=1` のときだけ使う。既存の `MONITORING_<MT名>` とは別のキー）。

**通知文の例**:
- `【発生】<MT 名> の自動配置 (ATST_AUTO_ATTACH_EA=1) が有効ですが、起動から <N> 分たってもモニタリングデータが出ていません。StartUp ini が効いていない可能性があります。確認: WINEPREFIX の drive_c/atst/startup_<名前>.ini (C:\atst\startup_<名前>.ini)、~/.atst/wine_<名前>.log、doctor.sh の auto_attach`
- `【継続中 30 分】…`（30 分 / 2 時間 / 12 時間後。上と同じ文面）
- `【復帰】<MT 名> の自動配置 (ATST_AUTO_ATTACH_EA=1) でモニタリングデータが出るようになりました。`
- `【復帰】<MT 名> の自動配置の確認を終了しました (ATST_AUTO_ATTACH_EA が 1 ではありません)。`（`0` に戻したとき）

**意味**: `mtctl.sh start` が作った StartUp ini（MT4 は ini のパスを素の引数、MT5 は `/config:<パス>` で渡す）で監視 EA を載せる設定なのに、MT が起動して `ATST_MONITORING_THRESHOLD` 秒たっても、起動後に書かれた CSV の行が無い。ini が読まれていない、通貨ペア・時間足がブローカーに無い、EA が自動売買の許可で動いていない、などが考えられる。止まっている MT や起動直後の MT は判定しない（止まっているときは `PROCESS_` の担当）。`MONITORING_<MT名>` も同時に出ることがあり、その場合はこちらの確認を先に、その後 [MONITORING_](#key-monitoring) を見る。

**確認コマンド**:
```bash
./doctor.sh
ls -l "$WINEPREFIX/drive_c/atst/"
tail -n 20 ~/.atst/wine_<名前を小文字にしたもの>.log
```
`doctor.sh` の `auto_attach` 行で、通貨ペア・時間足の値、ini の有無・権限（ディレクトリ 700・ファイル 600）、config との一致、動いている MT に ini の引数が渡っているか（MT4 は `C:\atst\startup_<名前>.ini`、MT5 は `/config:C:\atst\startup_<名前>.ini`）を見る。MT4 で `running with /config:, which MT4 ignores` なら旧版の起動のままなので `mtctl.sh stop` → `start` する。wine のログの `auto_attach:` 行は、ini を渡して起動したか（MT4 は `auto_attach: C:\atst\startup_<名前>.ini`、MT5 は `auto_attach: /config:C:\atst\startup_<名前>.ini`）、渡さずに起動した理由（`skipped (<理由>)`）が分かる。

**安全な復旧手順**:
- `doctor.sh` が `NG` の項目を直す（通貨ペア・時間足の値は `~/.atst/config` の `ATST_AUTO_ATTACH_SYMBOL` / `ATST_AUTO_ATTACH_PERIOD`。ブローカーの気配値表示にある名前にする）。
- MT を止めて `start` し直すときは、[安全の原則](#安全の原則)の (a)〜(c) を済ませてから `env -u WINEPREFIX ./mtctl.sh stop "<MT 名>"` → `start "<MT 名>"`。手で `start` するときは `ATST_TARGETS` と同じ名前を使う。
- 直らないときは VNC で手作業の配置（[MONITORING_](#key-monitoring) の手順）に切り替え、`ATST_AUTO_ATTACH_EA=0` に戻して `stop` → `start` すると、この通知は【復帰】で閉じる。

**それでも直らないとき**: MT の再インストールはせず、`./doctor.sh` の出力を Issue に貼って相談する。その間は手作業で EA を載せれば監視は動く。手で置いたチャートと自動配置のチャートで EA が二重にならないよう注意する（同じ CSV に 2 つの EA が書く）。

**関連**: [docs/monitoring-csv.md](monitoring-csv.md)、[README](../README.md)「監視 EA の自動配置」、#133、#141（継続中の通知）。

<a id="key-ping"></a>

### PING_<MT名>: Ping の異常値

**キー名**: `PING_<MT名>`。

**通知文の例**:
- `【発生】<MT 名> のPingが 600ms 以上の異常値になっています。現在のPing: <N>ms`（既定のしきい値）
- `【復帰】<MT 名> のPingが 300ms 以下の正常値に戻りました。現在のPing: <N>ms`

**意味**: `check_ping.sh` が、CSV の最後の行の 6 列目（MT とブローカーのサーバーの間の Ping。**マイクロ秒**）を見て出す。しきい値は `ATST_THRESHOLD_PING_UPPER` / `ATST_THRESHOLD_PING_LOWER`（マイクロ秒。既定 600000 / 300000）。通知は ms で表示する。CSV が無いときは何もしない（`MONITORING_` の担当）。

**確認コマンド**:
```bash
tail -n 5 "<data>/MQL4/Files/terminal_monitoring.csv"
./doctor.sh
```
6 列目の推移と、`doctor.sh` の `csv` 行（CSV の更新が止まっていないか）を見る。

**安全な復旧手順**: 多くはブローカーのサーバー側・回線側の問題で、VPS 側でできることは少ない。様子見でよいことが多い。建玉があるならスマホの MT アプリで価格と約定を見る。

**それでも直らないとき**: 続くならブローカーのサーバーの変更（ブローカー側の手順）を検討する。建玉はスマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で見て、必要なら手動決済する。通知が多すぎるならしきい値を見直す（[LINE_QUOTA](#key-line-quota)）。

**関連**: [docs/monitoring-csv.md](monitoring-csv.md)、Wiki [setup_monitoring2](../../../wiki/setup_monitoring2)。

<a id="key-price"></a>

### PRICE_<MT名>: 10 分の値幅の異常値

**キー名**: `PRICE_<MT名>`。

**通知文の例**:
- `【発生】<MT 名> の過去10分の値幅が 100 pips 以上の異常値になっています。高値:<高値>, 安値:<安値>, 10分値幅: <N> pips`（既定のしきい値）
- `【復帰】<MT 名> の過去10分の値幅が 50 pips 以下の正常値に戻りました。高値: <高値>, 安値: <安値>, 10分値幅: <N> pips`

**意味**: `check_price.sh` が、過去 10 分の CSV の 3 列目（Bid）の最大と最小の差を 7 列目（1 pip の価格）で割った値幅を見て出す。しきい値は `ATST_THRESHOLD_PRICE_UPPER` / `ATST_THRESHOLD_PRICE_LOWER`（pips。既定 100 / 50）。

**確認コマンド**:
```bash
tail -n 20 "<data>/MQL4/Files/terminal_monitoring.csv"
```
あわせてスマホの MT アプリでチャートを見る。

**安全な復旧手順**: 相場要因（指標発表・急変動）が多く、VPS 側で直すものは無い。EA が建玉を持っているなら、スマホの MT アプリで建玉と含み損益を確認し、必要なら手動決済する。

**それでも直らないとき**: スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見続ける。EA の挙動が想定と違うなら、EA を止めるかどうかは建玉と相場を見て判断する（VPS 側の操作は [安全の原則](#安全の原則) に従う）。

**関連**: [docs/monitoring-csv.md](monitoring-csv.md)、Wiki [setup_monitoring2](../../../wiki/setup_monitoring2)。

<a id="key-spread"></a>

### SPREAD_<MT名>: 5 分のスプレッド最高値の異常値

**キー名**: `SPREAD_<MT名>`。

**通知文の例**:
- `【発生】<MT 名> の5分間のスプレッド最高値が 60 以上の異常値になっています。5分間のスプレッド最高値: <N>`（既定のしきい値）
- `【復帰】<MT 名> の5分間のスプレッド最高値が 30 以下の正常値に戻りました。5分間のスプレッド最高値: <N>`

**意味**: `check_spread.sh` が、過去 5 分の CSV の 5 列目（スプレッド。単位は point）の最大値を見て出す。しきい値は `ATST_THRESHOLD_SPREAD_UPPER` / `ATST_THRESHOLD_SPREAD_LOWER`（既定 60 / 30）。

**確認コマンド**:
```bash
tail -n 20 "<data>/MQL4/Files/terminal_monitoring.csv"
```

**安全な復旧手順**: 指標発表・早朝（ロールオーバーの前後）・週明けに出やすく、様子見でよいことが多い。建玉があるならスマホの MT アプリで価格を見る。

**それでも直らないとき**: スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見て、必要なら手動決済する。頻繁に届くならしきい値を見直す（通知数の面でも。[LINE_QUOTA](#key-line-quota)）。

**関連**: [docs/monitoring-csv.md](monitoring-csv.md)、Wiki [setup_monitoring2](../../../wiki/setup_monitoring2)。

<a id="key-order"></a>

### ORDER（キー無し）: 約定通知・約定通知を LINE が受け付けなかった

**キー名**: 無し（`alert_status` に記録しない）。

**通知文の例**:
- 約定通知: EA が `<data>/MQL4/Files/order_status` に書いた行がそのまま届く（文面は EA が組み立てる）。
- `約定通知 (<N> 行) を LINE が受け付けませんでした。内容は次のファイルに保存しました: <data>/MQL4/Files/order_status.failed`

**意味**: `check_order.sh` が毎分 2 回、EA の書いた約定の行を LINE に送る。送れなかった分は `order_status.pending` に残り、次の回に自動で送り直す。LINE が内容を理由に拒否した分だけは `order_status.failed` に移して、短い通知だけを送る。

**確認コマンド**:
```bash
ls -l "<data>/MQL4/Files/"order_status*
grep 'LINE send failed' ~/.atst/line_error.log | tail -n 5
```
`order_status.failed` の中身は `cat "<data>/MQL4/Files/order_status.failed"` で見られるが、口座の情報を含むので、そのまま貼らない。

**安全な復旧手順**:
- 約定そのものは異常ではない。想定外の約定なら、スマホの MT アプリで建玉と履歴を確認し、必要なら手動決済する。
- `.pending` が残り続けるなら LINE 側の問題（トークンの失効・送信数の上限・送信先 ID の誤り）。`./doctor.sh` の `.line_token` / `.line_id` / `line_error.log` 行を見て、必要なら `./setup_line.sh` で入れ直す。上限なら [LINE_QUOTA](#key-line-quota)。

**それでも直らないとき**: 約定の通知が届かない間は、スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉と履歴を見る。LINE の送信失敗が続くと外形監視に `/fail`（`LINE_SEND_FAILED`）が届く（[HEARTBEAT](#key-heartbeat)）。

**関連**: [docs/monitoring-csv.md](monitoring-csv.md)（`order_status`）、Wiki [setup_line](../../../wiki/setup_line)。

<a id="key-runner-stuck"></a>

### RUNNER_STUCK: 毎分の監視が前の回で止まっている

**キー名**: `RUNNER_STUCK`。

**通知文の例**:
- `【発生】毎分の監視 (check_all.sh) が、前回の実行が終わらないため <N> 秒以上止まっています`
- `【継続中 30 分】毎分の監視 (check_all.sh) が、前回の実行が終わらないため <N> 秒以上止まっています`（30 分 / 2 時間 / 12 時間後）
- `【復帰】毎分の監視 (check_all.sh) が再開しました`

**意味**: `check_all.sh` は 1 回ずつしか動かない（`~/.atst/check_all.lock`）。次の回がロックを取れず、前の回の開始（`~/.atst/check_all.started`）から約 22 分（既定。`ATST_CHECK_TIMEOUT` に応じて変わる）以上たっていると出す。各チェックの打ち切り（`RUNNER_TIMEOUT_`）でも止まらない何かが残っている。**この間は毎分の監視が全部止まっている**。

**確認コマンド**:
```bash
date -d @"$(cat ~/.atst/check_all.started)"
echo $(( $(date +%s) - $(cat ~/.atst/check_all.started) ))
pgrep -af 'check_|heartbeat'
ps -o pid,etimes,stat,cmd -p <pid>
uptime
tail -n 50 ~/.atst/log/check_all.log
```
1 行目が前の回の開始時刻、2 行目が経過秒。`pgrep` で残っている `check_*.sh` / `heartbeat.sh` を探し、`ps` の `etimes`（経過秒）が長いものを `<pid>` に入れて見る。`check_all.log` に `another run holds the lock` の行が毎分続いていれば止まったまま。

**安全な復旧手順**:
1. 止まっている子（`check_*.sh` / `heartbeat.sh` / その下の `curl`）を pid で特定する。
2. その pid が MT（`env -u WINEPREFIX ./mtctl.sh status "<MT 名>"` の pid）と**違う**ことを確かめる。
3. その子だけを止める。
   ```bash
   kill <pid>
   ```
   効かなければ pid を確かめ直してから `kill -KILL <pid>`。
4. 次の回が動き出すと `【復帰】` が届く。

**それでも直らないとき**: `uptime` の load が高い・`top` で wineserver や MT が張り付いているなら [MT の固まりの切り分け](#mt-の固まりの切り分け)へ。監視が止まっている間は、スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見る。

**関連**: [README](../README.md)「毎分の監視 (check_all.sh) の動き」、#141（継続中の通知）、#144（`check_all.log`）。

<a id="key-runner-timeout"></a>

### RUNNER_TIMEOUT_<名前>: チェックが時間内に終わらない

**キー名**: 次の 8 個（チェックごと）。
- `RUNNER_TIMEOUT_CHECK_REBOOT`（`check_reboot.sh`）
- `RUNNER_TIMEOUT_CHECK_ORDER`（`check_order.sh`）
- `RUNNER_TIMEOUT_CHECK_PROCESS`（`check_process.sh`）
- `RUNNER_TIMEOUT_CHECK_MONITORING`（`check_monitoring.sh`）
- `RUNNER_TIMEOUT_CHECK_PING`（`check_ping.sh`）
- `RUNNER_TIMEOUT_CHECK_PRICE`（`check_price.sh`）
- `RUNNER_TIMEOUT_CHECK_SPREAD`（`check_spread.sh`）
- `RUNNER_TIMEOUT_HEARTBEAT`（`heartbeat.sh`。上限は 60 秒）

**通知文の例**:
- `【発生】チェックが 40 秒で終わらず打ち切りました: check_ping.sh`
- `【復帰】チェックが時間内に終わるようになりました: check_ping.sh`

**意味**: `check_all.sh` が各チェックを `ATST_CHECK_TIMEOUT` 秒（1〜300、既定 40。ハートビートは 60 秒）で打ち切ったときに出す。原因は LINE や外部サービスの応答の遅れ、ディスク、CPU の張り付き（MT の固まり・wineserver）が多い。`ATST_TARGETS` が空の間は `CHECK_REBOOT` と `HEARTBEAT` 以外は動かない。

**確認コマンド**:
```bash
uptime
top -b -n 1 | head -n 15
df -h ~
grep 'LINE send failed' ~/.atst/line_error.log | tail -n 5
tail -n 50 ~/.atst/log/check_all.log
./doctor.sh
```
`check_all.log` の `check_<名前>.sh: exit 124`（TERM で打ち切り）/ `exit 137`（KILL）の行で、どの回のどのチェックかが分かる。

**安全な復旧手順**:
1. 1 回だけで次の分に `【復帰】` が来るなら様子見でよい。
2. 続くなら `top` で張り付いているプロセスを見て、MT や wineserver なら [MT の固まりの切り分け](#mt-の固まりの切り分け)へ。`df -h ~` でディスクが一杯なら、`du -sh ~/.atst/* 2>/dev/null` などで大きいものを確かめる。`~/.atst/alert_status`・`~/.atst/config`・秘匿ファイル（`.line_token` など）・MT のフォルダ（`<data>` を含む）は消さない。消してよいか分からなければ消さずに相談する（`sudo` が要るものは範囲外）。
3. `ATST_CHECK_TIMEOUT` を大きくするのは最後の手段（`~/.atst/config` の末尾に書く）。

**それでも直らないとき**: 監視が部分的に効いていないので、スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見る。`./doctor.sh` の出力と `check_all.log` の末尾（目で確かめてから）を Issue に貼って相談する。

**関連**: [README](../README.md)「毎分の監視 (check_all.sh) の動き」、#144（`check_all.log`）。

<a id="key-runner-targets-empty"></a>

### RUNNER_TARGETS_EMPTY: 監視対象が設定されていない

**キー名**: `RUNNER_TARGETS_EMPTY`。

**通知文の例**:
- `【発生】監視対象が設定されていません。~/.atst/config の ATST_TARGETS に MetaTrader のフォルダ名を書いてください (MetaTrader ごとの監視と約定通知、再起動時の MetaTrader の自動起動が止まっています)`
- `【復帰】監視対象が設定されました`

**意味**: `check_all.sh` が毎分、`ATST_TARGETS` が未設定・空、または config の書き間違いでその行まで読まれていないのを見て出す。**この間は再起動の検出・ハートビート・朝の定期通知だけが動き、MT ごとの監視・約定通知・再起動時の自動起動は止まっている**。

**確認コマンド**:
```bash
grep -n 'ATST_TARGETS' ~/.atst/config
bash -n ~/.atst/config
./doctor.sh
tail -n 50 ~/.atst/log/check_all.log
```
`bash -n` は構文の誤りがある行を表示する。`doctor.sh` の `NG ATST_TARGETS unset or empty` と、`[warn] ~/.atst/config may not have been read completely` が出ていないかを見る（`check_all.log` にも同じ `[warn]` が残る）。

**安全な復旧手順**:
1. `~/.atst/config` の末尾に `ATST_TARGETS=('Land Prime')` の形で書く（名前は `./mtctl.sh list` の `name=` の先頭部分。引用符と括弧の閉じ忘れが多い）。古い config には自動では入らない。
2. `bash -n ~/.atst/config` で何も表示されないことを確かめる。
3. 次の分に `【復帰】` が届いたら、止まっていた間に MT が落ちていないか `env -u WINEPREFIX ./mtctl.sh status "<MT 名>"` と `PROCESS_` の通知で確かめる。

**それでも直らないとき**: 監視も約定通知も止まっているので、スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見る。

**関連**: [README](../README.md)「監視するMT4/5の指定 (ATST_TARGETS)」。

<a id="key-image-report-default-changed"></a>

### IMAGE_REPORT_DEFAULT_CHANGED: デスクトップ画像の通知が既定 OFF になった（お知らせ）

**キー名**: `IMAGE_REPORT_DEFAULT_CHANGED`（送れたら値 1 のまま残る。復帰の通知は無い）。

**通知文の例**: `【お知らせ】デスクトップ画像の通知は既定 OFF になりました (口座番号・残高が写るため)。朝の定期レポートは文字要約 (ImgBB の API キーがあればグラフ画像も) になります。デスクトップ画像も送るには、setup_imgbb.sh で ImgBB の API キーを設定し、~/.atst/config に ATST_IMAGE_REPORT_DESKTOP=1 を書いてください。この通知は 1 度だけです。`

**意味**: 毎朝 9:00 の `check_daily.sh` が、config に `ATST_IMAGE_REPORT_DESKTOP` の行が無い（古い config の）とき（`ATST_IMAGE_REPORT_TERM=0` で定期レポートを止めている場合を除く）に 1 度だけ送る。異常ではない。

**確認コマンド**:
```bash
grep -n 'ATST_IMAGE_REPORT_DESKTOP' ~/.atst/config
./doctor.sh
```
`doctor.sh` の `.imgbb_key` 行で ImgBB のキーの有無が分かる。

**安全な復旧手順**: 対応は任意。デスクトップ画像が要らなければ何もしない。要るなら `./setup_imgbb.sh` でキーを設定し、`~/.atst/config` に `ATST_IMAGE_REPORT_DESKTOP=1` を書く（口座番号・残高が写った画像が第三者のホストに置かれるので勧めない）。

**それでも直らないとき**: 該当なし（運用への影響は無い）。

**関連**: [README](../README.md)「デスクトップ画像の通知の移行」、#135。

<a id="key-line-quota"></a>

### LINE_QUOTA: LINE の送信数が上限の 8 割を超えた

**キー名**: `LINE_QUOTA`（毎朝の `check_daily.sh` が記録する状態だけのキー。LINE の発生・復帰の通知は無く、8 割以上で 1、未満と上限の無いプランで 0。送信数を取得できなかった日は前の値のまま）。

**通知文の例**: 毎朝の `稼働OK！<uptime の出力>` に、次の 2 行が付く。
- `LINE 送信数(今月): <使用>/<上限>通`
- `【注意】LINE の今月の送信数が上限の8割を超えました。上限に達すると月末まで異常や約定の通知も届きません。`

**意味**: `check_daily.sh` が LINE の今月の送信数（無料プランは月 200 通）を見て、8 割以上なら付ける。**上限に達すると月末まで異常も約定も LINE に届かない**。値 1 の間は外形監視に `/fail` が届く（[HEARTBEAT](#key-heartbeat)）。

**確認コマンド**:
```bash
grep '^LINE_QUOTA,' ~/.atst/alert_status
grep 'LINE send failed' ~/.atst/line_error.log | tail -n 5
./doctor.sh
```
`line_error.log` の見出し行の `http=429` は上限に達したことを示す。

**安全な復旧手順**:
1. 通知の多いキー（`PING_` / `SPREAD_` / `PRICE_`）のしきい値を見直す（`~/.atst/config` の `ATST_THRESHOLD_*`）。継続中の通知を減らすなら `ATST_ALERT_REMIND_MINUTES`。
2. 外形監視（ハートビート）が設定されていることを `./doctor.sh` の `heartbeat` 行で確かめる（LINE が止まっても外部サービスから知らせが届く）。

**それでも直らないとき**: 上限に達したら、月末まではスマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉を見る。外形監視が頼りになる。

**関連**: [README](../README.md)「毎分の監視 (check_all.sh) の動き」（`/fail` になるもの）、#136。

<a id="key-image-upload-failed"></a>

### IMAGE_UPLOAD_FAILED（キー無し。RUNBOOK 側の名前）: 画像のアップロードに失敗した

**キー名**: 無し（独立した通知ではなく、本文の末尾に付く）。

**通知文の例**: `<本文> (画像アップロード失敗: <N>枚)`（主に朝の定期レポート）

**意味**: 画像を ImgBB に置けなかった枚数。本文は届いている。ImgBB のキーが無いときは画像を試さないので付かない。2026-10 に画像ホスト側の HTTP 500 で付いた実例がある。

**確認コマンド**:
```bash
./doctor.sh
grep 'upload:imgbb' ~/.atst/line_error.log | tail -n 5
```
`doctor.sh` の `.imgbb_key` 行（`mode 600 ****<末尾 4 文字>` / `not set (optional)`）と、`line_error.log` の見出し行の `http=upload:imgbb=<HTTP コード>` を見る。

**安全な復旧手順**: 画像ホスト側の障害なら様子見（翌朝には直ることが多い）。`401` / `403` など認証の誤りが続くなら `./setup_imgbb.sh` でキーを入れ直す（入力後にテスト画像をアップロードして確かめる。何も入力せずに Enter でキーを消すと、文字要約だけになる）。

**それでも直らないとき**: 画像が無くても運用には影響しない。キーを消して文字要約だけにしてもよい。

**関連**: [README](../README.md)「デスクトップ画像の通知の移行」、#135。

<a id="key-heartbeat"></a>

### HEARTBEAT（外部サービス側の通知）: 外形監視の通知が来た

**キー名**: 無し（外部サービス（Healthchecks.io など）が自分の文面でメールなどを送る）。打ち切りは別に `RUNNER_TIMEOUT_HEARTBEAT`（[RUNNER_TIMEOUT_](#key-runner-timeout)）。

**通知文の例**: 外部サービスによる（「down」「failed」など）。

**意味**: `check_all.sh` の最後に `heartbeat.sh` が毎分、外部サービスの URL（`~/.atst/.heartbeat_url`、無ければ config の `ATST_HEARTBEAT_URL`）へ送る。外部サービスからの通知は 2 種類ある。
- **ping が途絶えた**: VPS の停止・回線断・cron の停止・`check_all.sh` が最後まで届かない、のどれか。**このとき VPS からの LINE は届かない前提**で、**EA も動いていない前提**で動く。
- **`/fail` が届いた**: VPS は生きていて、監視が異常を検知している。`/fail` の本文は発生中のキー名（空白区切り）だけ。対象は `PROCESS_` / `TARGET_` / `MONITORING_` / `RUNNER_`（`RUNNER_TIMEOUT_HEARTBEAT` を除く）/ `LINE_QUOTA` と、LINE の送信失敗の連続（`LINE_SEND_FAILED`。`~/.atst/line_error.log` の直近 60 分に `ATST_HEARTBEAT_LINE_FAIL_COUNT` 件、既定 3）。LINE が届かない状況でも届く。

**確認コマンド**: まず ssh で入れるか。入れたら:
```bash
crontab -l
ls -l ~/.atst/check_all.started
pgrep -af check_all
grep ',1,' ~/.atst/alert_status
grep 'LINE send failed' ~/.atst/line_error.log | tail -n 5
./doctor.sh
```
`check_all.started` の更新時刻が直近（1〜2 分以内）なら毎分の監視は動いている。`doctor.sh` の `crontab -l` 行と `heartbeat` 行（`.heartbeat_url` と `ATST_HEARTBEAT_URL` のどちらが使われているか）を見る。URL を `curl` で手で叩かない（URL が履歴と `ps` に残る）。

**安全な復旧手順**:
- `/fail`: 外部サービスの画面（ログ）の本文か `grep ',1,' ~/.atst/alert_status` で発生中のキーを見て、そのキーの節へ。`LINE_SEND_FAILED` なら [ORDER](#key-order) の LINE 側の確認と [LINE_QUOTA](#key-line-quota)。監視対象から外した MT のキーが残って `/fail` が続く場合は、README「毎分の監視 (check_all.sh) の動き」に従ってそのキーの行を消す。
- ping の途絶で ssh が通らない: VPS 事業者のコンソールで状態を見る（再起動など `sudo` 相当の操作は範囲外）。
- ping の途絶で ssh が通る: `crontab -l` が空なら、退避してから `./setup_cron.sh` で登録し直す（空でなければ使わない。atst の行がある crontab には追記しない）。
  ```bash
  crontab -l > ~/crontab.bak
  ./setup_cron.sh
  ```
  `check_all.started` が古く `check_all` のプロセスが残っているなら [RUNNER_STUCK](#key-runner-stuck) と同じ手順。

**それでも直らないとき**: スマホの MT アプリ（[setup_mobile_mt](../../../wiki/setup_mobile_mt)）で建玉・残高を見て、必要なら手動決済する。朝まで待ってよいのは建玉が無いときだけ。

**関連**: [README](../README.md)「毎分の監視 (check_all.sh) の動き」、Wiki [setup_heartbeat](../../../wiki/setup_heartbeat)、#136。

## MT の固まりの切り分け

**症状**: `MONITORING_` の発生、VNC でクリックが効かない、`PROCESS_` は出ない（プロセスは居る）。

**確認（読み取り専用）**:
```bash
pid=$(env -u WINEPREFIX ./mtctl.sh status "<MT 名>" | sed -n 's/.*pid=\([0-9]*\),.*/\1/p')
[ -n "$pid" ] || echo "stopped"     # 名前の一致を ./mtctl.sh list で確かめ、合っていれば PROCESS_ の節へ
top -H -b -n 1 -p "$pid" | head -n 20     # スレッド別の CPU。TID が pid と同じ行が main thread
top -b -n 1 | grep -i wineserver     # wineserver も張り付いているか
ls -l "<data>/MQL4/Files/terminal_monitoring.csv"     # CSV の更新時刻
```
`top` が使えないときや数値で比べたいときは、`/proc/<pid>/task/*/stat` の 14・15 列目（utime・stime。単位は clock tick）を 5 秒あけて 2 回取り、差の大きいスレッドを見る（同じシェルで上の `pid=` を実行してから）。
```bash
a=$(for t in /proc/"$pid"/task/*; do echo "$(basename "$t") $(awk '{print $14+$15}' "$t/stat")"; done); sleep 5
b=$(for t in /proc/"$pid"/task/*; do echo "$(basename "$t") $(awk '{print $14+$15}' "$t/stat")"; done)
diff <(echo "$a") <(echo "$b")
```
スレッド名に空白があると列がずれることがあるので、主に `top -H` を使い、`/proc` は補助にする。

**判定**: `status=running` で CSV の更新が止まり、main thread か wineserver が 100% 近くに張り付いていれば固まり。張り付いていなければ EA がチャートから外れた可能性がある（[MONITORING_](#key-monitoring) の「ありません」側）。

**既知の原因**: ターミナル欄の「記事」タブ（埋め込みの Web 表示。Wine の `mshtml` と `mscoree` は無効にしてある）を開いたまま。2026-10 に 2 回、main thread と wineserver の CPU が張り付いて固まった。`@reboot` の直後にも同じ固まり方をした。

**復旧**:
1. [安全の原則](#安全の原則) の「MT を止める前に行うこと」（建玉の確認、pid と名前の確認）。
2. VNC で「記事」タブを「操作履歴」などに切り替えられるなら切り替え、CSV の更新が戻るか見る。
3. 効かなければ止める。
   ```bash
   env -u WINEPREFIX ./mtctl.sh stop "<MT 名>"
   env -u WINEPREFIX ./mtctl.sh status "<MT 名>"
   ```
   `./mtctl.sh stop` は TERM を送るだけなので、`status` が `stopped` になるまで数秒おきに確かめる。残るときは、`status` の pid が止める MT のものであることを確かめ直してから `kill -KILL <pid>`。
4. `stopped` を確かめてから起動する。
   ```bash
   env -u WINEPREFIX ./mtctl.sh start "<MT 名>"
   ```
5. VNC で口座の接続・「自動売買」ボタン・チャートの EA を確かめ、CSV の更新の再開と `MONITORING_` の `【復帰】` を待つ。

**建玉への影響**: 建玉はブローカー側にあり、MT の停止・再起動で消えない。止めている間（と固まっている間）は EA の決済が動かないので、建玉があるならスマホの MT アプリで価格を見ておく。

## VNC の既知の罠

- ターミナル欄の「記事」「マーケット」「ライブラリ」など、Web 表示を使うタブを開かない（固まりの原因。[MT の固まりの切り分け](#mt-の固まりの切り分け)）。
- クリックが数ピクセルずれるときは、MT の窓をタイトルバーで少し動かす（wm2 が枠を付けた後に、Wine が把握している窓の位置とずれる）。
- 右上の「閉じる」と「最小化」を取り違えない。閉じてしまったら `PROCESS_` の発生が届くので、[PROCESS_](#key-process) の手順で `start` する。
- EA の動作は「自動売買」ボタンの状態で確かめる（キーボードの操作ではなくボタンを見る）。
- VNC 自体の確認:
  ```bash
  ./vnc_status.sh
  ls -l ~/.vnc/*.log
  tail -n 20 ~/.vnc/*.log
  ```
  `vnc_status.sh` は `VNC Server is running at DISPLAY :1, pid=<pid>` か `VNC Server is not running.` を表示する。VNC の起動・再起動（`sudo` やサービスの操作）は範囲外。

## 秘匿値の扱い

- `sudo` が要るときは、先に `sudo -v` を打ってパスワードをプロンプトに入れてから本来のコマンドを打つ。パスワードやトークンをコマンドの引数・`echo` の引数に書かない（`ps` と履歴に残る）。
- 値を打ち込む必要があるときは `read -s` で読み、使い終わったら消す（画面にも履歴にも出ない）。
  ```bash
  read -s -p "> " v
  unset v
  ```
- `./setup_line.sh` / `./setup_imgbb.sh` / `./setup_heartbeat.sh` は入力した値が画面に表示される（履歴には残らない）。周りから画面が見えない状態で入力する。
- 履歴に残してしまったとき: `history | tail -n 30` で該当の行の番号を確かめ、その番号を `history -d` に渡して消し、最後に `history -w` で `~/.bash_history` にも反映する。
- 漏洩したときの失効・再発行:
  - LINE: LINE Developers のチャネル設定で、チャネルアクセストークン（長期）を再発行する（古いものは失効する）。そのあと `./setup_line.sh` で入れ直す。
  - ImgBB: api.imgbb.com でキーを再発行し、`./setup_imgbb.sh` で入れ直す。
  - ハートビートの URL: 外部サービス側で新しい URL を発行し、`./setup_heartbeat.sh` で入れ直す（`~/.atst/.heartbeat_url` が config の `ATST_HEARTBEAT_URL` より優先される。config に古い URL が残っていれば消す）。
- 貼ってよいもの: `./doctor.sh` の出力（ホームは `~`、トークン・キー・URL は末尾 4 文字、LINE ID は出さない）。ただし `check_all.log` の末尾の行は各チェックの出力そのままなので、貼る前に目で見る。
- 貼らないもの: `~/.atst/line_error.log` の `response:` / `message:` の行（通知の本文を含む。見出し行だけなら可）、`order_status.failed` と監視 CSV の中身（口座の情報を含みうる）、`~/.atst/.line_token` / `.line_id` / `.imgbb_key` / `.heartbeat_url`（`cat` しない）。
- これらの秘匿ファイルの権限は 600（`./doctor.sh` が検査し、違えば `NG`）。
