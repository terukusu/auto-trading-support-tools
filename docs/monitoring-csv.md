# 監視 CSV の列契約（atst）

監視 EA（`MQL4/Experts/TerminalMonitoring.mq4` / `MQL5/Experts/Advisors/TerminalMonitoring.mq5`）が書く `terminal_monitoring.csv` と `order_status` の契約をまとめる。`terminal_monitoring.csv` は外形監視（`check_monitoring.sh` / `check_tick.sh` / `check_trade_ready.sh` / `check_price.sh` / `check_spread.sh` / `check_ping.sh`、`report_image.sh`、`truncate_monitoring.sh`、`doctor.sh`）の唯一の入力なので、**列・書式・書き方を変える PR はこの文書を同じ PR で更新する**。

MQL の行番号は `iconv -f UTF-16LE -t UTF-8 <file> | tr -d '\r' | cat -n` で数えたもの（BOM の行が 1 行目）。bash 側は行番号を書かず、スクリプト名と awk の式で示す。

## 目次

- [対象ファイルと置き場](#対象ファイルと置き場)
- [列表](#列表)
- [書き手（監視 EA）](#書き手監視-ea)
- [読み手](#読み手)
- [部分行・空行・CR の規則](#部分行空行cr-の規則)
- [時刻の基準](#時刻の基準)
- [order_status](#order_status)
- [互換の規則](#互換の規則)
- [状態ファイルの予約（#137）](#状態ファイルの予約137)
- [MQL4 と MQL5 の差](#mql4-と-mql5-の差)
- [既知の不一致](#既知の不一致)

## 対象ファイルと置き場

- `<mt_data>/MQL4/Files/terminal_monitoring.csv`（MT5 は `<mt_data>/MQL5/Files/terminal_monitoring.csv`）。
- `<mt_data>` は `lib/atst_mt.sh`（`common.sh` が source する）の `atst_find_mt_data_dir` が決める MT のデータフォルダ（グローバル配列 `mt_data`）。AppData 側（`.../MetaQuotes/Terminal/<hash>`）か、無ければインストール先。
- パスは `atst_get_monitoring_csv_path <name>` で得る（= `atst_get_mql_folder_path` + `/Files/terminal_monitoring.csv`）。MT が見つからなければ空を返す。
- `order_status` も同じ `Files/` 直下（`check_order.sh` は `$(atst_get_mql_folder_path <name>)/Files/order_status` を読む）。

## 列表

**このページで 1 列目が数字だけの表はこの表だけ**にする（他の表の 1 列目は文字）。M4 = `TerminalMonitoring.mq4`、M5 = `TerminalMonitoring.mq5`。

| # | 名前 | 意味 | 型・書式 | 単位・時刻基準 | MQL4（行） | MQL5（行） | 読み手と用途 |
|---|---|---|---|---|---|---|---|
| 1 | time_gmt | 書き込んだ時刻 | epoch 秒の 10 進整数 | **UTC**。`TimeGMT()` は端末（Wine）のローカル時計と TZ から算出する（Wine 側の TZ が誤っているとずれる）。読み手は Linux の `date +%s` と直接比較する | M4:138 `(string)TimeGMT()` | M5:143 `(string)(long)TimeGMT()` | `check_monitoring.sh` / `doctor.sh`（鮮度）、`check_price.sh`（直近 600 秒）、`check_spread.sh`（直近 300 秒）、`report_image.sh`（期間の絞り込み・最終データ時刻・グラフの x）、`truncate_monitoring.sh`（保持期間）、`draw_graph.sh`（x 軸。`3600*9` を足す） |
| 2 | time_server | 最後のティックのサーバー時刻 | epoch 形式の整数 | 取引サーバーの時刻（**ブローカーの TZ。UTC ではない**）。`TimeCurrent()` は最後のティック受信時刻で、ティックが止まると進まない | M4:139 `(string)TimeCurrent()` | M5:144 `(string)(long)TimeCurrent()` | `check_tick.sh`（`ATST_TICK_THRESHOLD` 秒の窓の中で値が変わったか。列 1 との差は使わない）。テストの行は既定 0（`atst_test_make_monitoring_csv` の第 7 引数で指定） |
| 3 | bid | Bid | 小数。double を `(string)` で文字列化した既定の書式（桁数は保証しない） | 価格 | M4:140 `(string)Bid` | M5:145 `(string)Bid`（M5:124-127 で `SymbolInfoTick` の `last_tick.bid` を代入） | `check_price.sh`（min/max）、`report_image.sh`（要約の安値・高値、グラフの y） |
| 4 | ask | Ask | 列 3 と同じ | 価格 | M4:141 `(string)Ask` | M5:146 `(string)Ask`（`last_tick.ask`） | 現行の読み手なし |
| 5 | spread | スプレッド | 整数（MQL4 は `MarketInfo` の double を `(string)` 化するため書式は実機未確認。K8） | **point**（pip ではない。5 桁ブローカーでは pip × 10）。`ATST_THRESHOLD_SPREAD_*` と同じ単位。`report_image.sh` のグラフの軸ラベルは「pips x 10」 | M4:142 `(string)MarketInfo(Symbol(),MODE_SPREAD)` | M5:147 `(string)SymbolInfoInteger(Symbol(),SYMBOL_SPREAD)` | `check_spread.sh`（最大値）、`report_image.sh`（要約の最小・最大、グラフ） |
| 6 | ping | 直近の ping | 整数 | **マイクロ秒**。`ATST_THRESHOLD_PING_*` と同じ単位 | M4:143 `(string)TerminalInfoInteger(TERMINAL_PING_LAST)` | M5:148 同じ | `check_ping.sh`（`/1000` して ms で表示） |
| 7 | pip | 1 pip の価格 | 小数 4 桁。`Digits<=3` なら `0.0100`、`>=4` なら `0.0001`。0 にはならない | 価格 | M4:144 `DoubleToStr(pricePerPip(),4)`（関数は M4:251-264） | M5:149 `DoubleToString(pricePerPip(),4)`（M5:268-281） | `check_price.sh` / `report_image.sh`（値幅 ÷ pip） |
| 8 | symbol | シンボル名 | 文字列（通常は ASCII） | — | M4:145 `Symbol()+","` | M5:150 同じ | `report_image.sh`（表示用）。#158 より前の EA（8 列）では最終列なので CRLF 環境では `\r` が付きうる |
| 9 | connected | ブローカーに接続しているか | `0` / `1` | — | M4:147 `(string)TerminalInfoInteger(TERMINAL_CONNECTED)` | M5:152 同じ | `check_trade_ready.sh`（0 なら不良。理由「ブローカーに接続していません」） |
| 10 | trade_allowed | 端末の自動売買ボタン（「自動売買」/「Algo Trading」）が ON か | `0` / `1` | — | M4:148 `(string)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)` | M5:153 同じ | `check_trade_ready.sh`（0 なら不良。理由「端末の自動売買ボタンが OFF です」） |
| 11 | account_trade | 口座で取引が許可されているか（閲覧専用のパスワードでのログインなどで 0） | `0` / `1` | — | M4:149 `(string)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)` | M5:154 同じ | `check_trade_ready.sh`（0 なら不良。列 9 が 0 の間は理由に出さない） |
| 12 | account_expert | 口座で EA の取引が許可されているか（ブローカー側の設定） | `0` / `1` | — | M4:150 `(string)AccountInfoInteger(ACCOUNT_TRADE_EXPERT)` | M5:155 同じ | `check_trade_ready.sh`（0 なら不良。列 9 が 0 の間は理由に出さない） |
| 13 | positions | 建玉数 | 0 以上の整数 | 件。MQL4 は待機注文を含む、MQL5 はポジションだけ（ネッティング口座では銘柄ごとに 1） | M4:151 `(string)OrdersTotal()` | M5:156 `(string)PositionsTotal()` | 現行の読み手なし（書くだけ） |
| 14 | margin_level | 証拠金維持率 | 小数 2 桁 | %。建玉が無いときは `0.00` | M4:152 `DoubleToStr(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),2)+"\n"` | M5:157 `DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),2)+"\n"` | 現行の読み手なし（書くだけ）。最終列なので CRLF 環境では `\r` が付きうる |

例（値は架空。時刻 2 つの差は例示）:

```text
1760000000,1760007200,150.123,150.125,20,35000,0.0100,USDJPY,1,1,1,1,2,1234.56
```

- 区切りは `,` 固定、クォート無し。改行は LF（列 14 の文字列に `"\n"` を連結して `FileWriteString` に渡す）。
- EA は毎回 14 列を書く（空の列は無い）。欠けるのは書きかけの行だけ（[書き手](#書き手監視-ea)）。
- 列 9〜14 は #158 で末尾に足した（[互換の規則](#互換の規則) a）。#158 より前の EA は列 1〜8 だけを書き（行末は列 8 の `"\n"`）、EA を更新して載せ直すまで 8 列の行が続く。8 列と 14 列の行は同じファイルに混在しうる（規則 e）。`doctor.sh` の `csv` の行の `cols N` で最終行の列数が分かる。
- 14 列の根拠: `iconv -f UTF-16LE -t UTF-8 <EA> | sed -n '/FileOpen("terminal_monitoring.csv"/,/FileClose/p' | grep -c FileWriteString` が M4・M5 とも `14`（列 9 の直前のコメント行 M4:146 / M5:151 は `FileWriteString` を含まない）。

## 書き手（監視 EA）

- **間隔**: `OnInit` が `EventSetTimer(INTERVAL)`（M4:84 / M5:81）。`INTERVAL` の既定は 15 秒（M4:13 `extern int` / M5:10 `input int`）。`OnTimer` が `PerformMonitoring` を呼び、1 回に 1 行追記する。`OnDeinit` で `EventKillTimer`。
- **ストラテジーテスター**: `OnTick` が `TimeCurrent()` の経過で `OnTimer()` を呼び、タイマーを模倣する（M4 は `IsTesting()`、M5 は `MQL_TESTER`）。
- **書き方**: `FileOpen` → `FileSeek(handle,0,SEEK_END)` → `FileWriteString` を 14 回 → `FileClose`（M4:132-153 / M5:137-158）。**`FileFlush` は呼ばない**。1 行を 14 回の書き込みで作るので、読み手はその途中（書きかけの行）を見うる。
- **失敗時**: `FileOpen` が `INVALID_HANDLE` なら `Print("Operation FileOpen failed, error ",GetLastError())` だけ。その回の行は書かれず、次のタイマーで改めて書く（再試行の処理は無い）。
- **書く条件**: 接続状態・取引可否に関係なく毎回書く（接続・取引可否は列 9〜12 に書くが、書くかどうかの条件には使わない）。したがって「CSV が更新されている」は「MT が固まっていない」の意味にしかならず、取引できるかは列 9〜12 で見る（#137・#158 の背景）。MT4 で端末の自動売買ボタンを OFF にしたときに監視 EA の `OnTimer` が止まらないか（列 10 が 0 の行が書かれるか）は実機で未確認。
- **削除・切り詰め**: EA はしない。古い行は `truncate_monitoring.sh` が消す。
- **文字コード**: `FileOpen` のフラグをそのまま書く。
  - M4:132 `FileOpen("terminal_monitoring.csv",FILE_READ|FILE_WRITE|FILE_TXT,0,CP_UTF8)`（`FILE_ANSI` / `FILE_UNICODE` は無し、コードページ `CP_UTF8`）
  - M5:137 `FileOpen("terminal_monitoring.csv",FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI,0)`（コードページ指定なし＝既定）
  - 区切りの引数（どちらも 0）は `FileWriteString` には効かない。
  - 列 1〜7・9〜14 は ASCII の数値、列 8 も通常のシンボル名は ASCII。読み手は 1 バイト文字の行として `awk -F,` で読んでいる。**出力のバイト列は実機で確認していない**（[既知の不一致](#既知の不一致) K7）。非 ASCII のシンボル名は未検証。

## 読み手

表の 1 列目がスクリプト名、2 列目が使う列番号（空白区切り）。`awk -F'|'` で分けると `$2` がスクリプト名、`$3` が列番号になる。

| スクリプト | 使う列 | 区分 | 読み方 | 前提・判定 |
|---|---|---|---|---|
| `check_monitoring.sh` | 1 | 監視 | `tail -n 20 \| tr -d '\r' \| awk -F, 'NF >= 8 && $1 ~ /^[0-9]+$/ {t = $1} END {print t}'`（最後の完全な行） | `now - t >= ATST_MONITORING_THRESHOLD`（既定 180 秒）で発生。行が無ければ MT プロセスの有無と起動からの経過を見て、稼働中かつ猶予を過ぎていれば「データがありません」 |
| `check_tick.sh` | 1 2 | 監視 | `tr -d '\r'` した全体を `awk -F,` で 1 回走査し、`NF >= 8 && $1 ~ /^[0-9]+$/ && $2 ~ /^[1-9][0-9]*$/` の行だけを使う（最後の行の列 1 = last1、`last1 - T <= 列 1 <= last1` を窓、`T` = `ATST_TICK_THRESHOLD`（既定 600 秒）。列 1 > last1 の行は窓に入れない） | 判定しない: CSV・完全な行が無い、`now - last1 >= ATST_MONITORING_THRESHOLD`（CSV の停止は `MONITORING_`）、last1 が UTC の金 20:00〜月 00:00（`ATST_TICK_WEEKEND_SKIP=0` で判定）、窓の外側（`列 1 < last1 - T`）に行が無い、窓の中の行の列 1 の間隔（窓内の最初の行は直前の窓外の行から）に `ATST_MONITORING_THRESHOLD` 秒以上の空白がある（MT / 監視 EA の再開直後。EA は CSV を切り詰めないので停止前の行が窓外に残る）。窓内の列 2 の最小と最大が同じなら `TICK_<MT>` 発生、違えば復帰 |
| `check_trade_ready.sh` | 1 9 10 11 12 | 監視 | `tr -d '\r'` した全体を `awk -F,` で 1 回走査し、`NF >= 14 && $1 ~ /^[0-9]+$/` かつ列 9〜12 がそれぞれ `^[01]$` の行（完全な行）だけを使う（8 列の行は窓にも窓外にも間隔の計算にも入れない）。窓は `check_tick.sh` と同じ（`T` = `ATST_TRADE_READY_THRESHOLD`、既定 300 秒） | 判定しない: CSV・完全な行が無い（古い EA の 8 列だけ。stderr にも出さない）、`now - last1 >= ATST_MONITORING_THRESHOLD`、last1 が UTC の金 20:00〜月 00:00（`ATST_TRADE_READY_WEEKEND_SKIP=0` で判定。判定は common.sh の `atst_is_weekend_epoch`）、窓の外側に完全な行が無い、窓の中に `ATST_MONITORING_THRESHOLD` 秒以上の空白がある（`check_tick.sh` と同じ規則）。窓内の完全な行がすべて不良（列 9〜12 のどれかが 0）なら `TRADE_<MT>` 発生、すべて良好（すべて 1）なら復帰、混在は状態を保つ。理由は最後の完全な行の列 9〜12 から作り、列 9 が 0 のときは列 11・12 の理由を出さない（切断中の口座情報は当てにならない）。列 13・14 は使わない |
| `doctor.sh` | 1 | 診断 | `check_monitoring.sh` と同じ式（最後の完全な行の `NF` も取る） | ファイル無し・行無し・`ATST_MONITORING_THRESHOLD` 秒以上古いときに NG。`last update` の行の末尾に `cols <NF>`、14 未満なら古い EA の補足行（判定は変えない。書きかけの行を読んだ瞬間は 9〜13 になりうるが表示だけ） |
| `check_price.sh` | 1 3 7 | 監視 | 列 1・3: ファイル全体を `awk -F, 'BEGIN{min=10000; max=0} NF >= 8 { if ($1 > from) ...}'`（`from` = 600 秒前）で列 3 の min/max。CR 除去なし、列 1 の数値ガードなし。列 7: `tail -n 20 \| tr -d '\r' \| awk -F, 'NF >= 8 {p = $7} END {print p}'` | 列 7 は `^[0-9]*\.?[0-9]+$` かつ 0 でないこと。`(max - min) / pip` を `ATST_THRESHOLD_PRICE_UPPER` / `LOWER`（pips）と比較 |
| `check_spread.sh` | 1 5 | 監視 | ファイル全体を `awk -F, 'BEGIN{max=0} NF >= 8 { if ($1 > from) ...}'`（`from` = 300 秒前）で列 5 の最大。CR 除去なし、列 1 の数値ガードなし | 結果が `^[0-9]+$` であること。`ATST_THRESHOLD_SPREAD_UPPER` / `LOWER`（point）と比較 |
| `check_ping.sh` | 6 | 監視 | `tail -n 20 \| tr -d '\r' \| awk -F, 'NF >= 8 {p = $6} END {print p}'` | `^[0-9]+$` であること。`ATST_THRESHOLD_PING_UPPER` / `LOWER`（マイクロ秒）と比較 |
| `report_image.sh` | 1 3 5 7 8 | レポート | 列 8: `tail -n 20 \| tr -d '\r'` の最後の完全な行（表示用）。要約: `tr -d '\r'` した全体を `NF >= 8 && $1 > from` で絞り、列 5 の最小・最大、列 3 の安値・高値、最後の列 7（pip）と列 1（最終データ時刻）。グラフ: 同じ条件で (列 1, 列 5) と (列 1, 列 3) を `draw_graph.sh` へ（こちらは CR 除去なし） | `from` は `ATST_IMAGE_REPORT_TERM` 時間前。値幅 pips は pip が正の数でなければ `-`。最終データ時刻は `date -d` でホストのローカル TZ で表示 |
| `draw_graph.sh` | 1 | レポート | CSV を直接は読まず、stdin の `epoch,value` を `plot '-' using ($1+3600*9):2` で描く | x 軸は列 1 に 9 時間を固定で足した JST 表示 |
| `truncate_monitoring.sh` | 1 | 保守 | `awk -F, '{if ($1 > from) print}'`（`from` = `ATST_MONITORING_TRUNCATE_BEFORE` 日前）で同じディレクトリの `mktemp` に書き、`mv` で置換 | `NF` ガード・CR 除去なし。awk の読み終わりから `mv` までに EA が追記した行は失われうる（最大 1 行。次の `INTERVAL` で回復） |
| `mtctl.sh` | なし | 表示 | `monitor` サブコマンドが `tail -f` で生のまま表示する | 列を解釈しない |
| `check_order.sh` | なし | 注文通知 | CSV は読まない。`order_status` だけ（[order_status](#order_status)） | — |
| `tests/test_helper.bash` | 1 2 3 4 5 6 7 8 | テスト | `atst_test_make_monitoring_csv` が `<epoch>,<time_server>,<bid>,<bid>,<spread>,<ping>,<pip>,USDJPY` を `MQL4/Files/terminal_monitoring.csv` に追記（sandbox 内のみ）。第 8 引数が空でなければ `,<第 8 引数>` を足して列 9 以降にする（例 `1,1,1,1,0,0.00` で 14 列） | 列 2 は第 7 引数（既定 0）、列 4 は bid と同値、ping の既定は 12（マイクロ秒）。`tests/check_monitoring.bats` は書きかけの行（列 1 の途中まで、改行無し）を実際に作って試す |

- 現行の読み手が使わない列: 4、13、14。
- `heartbeat.sh` は CSV を読まない（`check_monitoring.sh` が立てた `MONITORING_*` の状態を見るだけ）。

## 部分行・空行・CR の規則

- 読み手は「`NF >= 8` を満たす最後の行」を **最後の完全な行** として使う。末尾の書きかけの行（列が 8 に満たない行）と空行は無視する。列 9〜12 を使う `check_trade_ready.sh` だけは `NF >= 14` かつ列 9〜12 が `0` / `1` の行を完全な行とする（列 13 の後の `,` までで切れた書きかけの行は `NF` が 14 で列 14 が空になり、完全な行に数えうる。列 9〜12 は書き終わっているので判定には影響しない。K12）。
- 最新値を見る読み手は `tail -n 20` の範囲だけを見る（15 秒間隔で約 5 分ぶん）。20 行すべてが書きかけということは通常無い。`check_tick.sh` は時刻の窓で判定するので全件を走査する（行数に依存しない。K10）。
- CR は行末の列（列 14。#158 より前の EA では列 8）や最後の値を読むときに `tr -d '\r'` で除去する。行末でない列だけを比較する全件走査では除去しないものがある（影響なし）。
- 列 1 が数値（`^[0-9]+$`）でない行を無視するのは `check_monitoring.sh` / `check_tick.sh` / `check_trade_ready.sh` / `doctor.sh` だけ（`check_tick.sh` は列 2 も正の整数であることを、`check_trade_ready.sh` は列 9〜12 がそれぞれちょうど `0` か `1` であることを要求する）。
- 読み手ごとの実装は [読み手](#読み手) の表、揃っていない点は [既知の不一致](#既知の不一致) を参照。

## 時刻の基準

- 列 1 は `TimeGMT()` の UTC epoch 秒。読み手は Linux の `date +%s`（UTC epoch）と直接比較する。Wine 側の時計・TZ が誤っていると鮮度判定がずれる。
- 列 2 は `TimeCurrent()` の取引サーバー時刻で、ブローカーの TZ（UTC ではない）。最後のティック受信時刻なので、市場が閉じている間・ティックが止まっている間は進まない。
- `draw_graph.sh` だけは表示用に列 1 へ `3600*9` を固定で足す（JST 固定。ホストや利用者の TZ に依らない）。
- `report_image.sh` の「最終データ」の表示は `date -d` によるホストのローカル TZ。

## order_status

- 置き場: `<mt_data>/MQL4/Files/order_status`（MT5 は `MQL5/Files/`）。CSV ではなくテキストで、1 件 1 行（LF 終端）。
- 書く回: ポジションの変化（新規・決済）があったタイマー回だけ、その回の分をまとめて追記する（`msg` が空なら書かない）。EA は毎回ファイル名で開き直す（`FileOpen` → `FileSeek` 末尾 → `FileWriteString(msg)` → `FileClose`）。EA は削除しない。`FileOpen` 失敗時は `Print` だけ。
- `FileOpen`: M4:225 `FileOpen("order_status",FILE_READ|FILE_WRITE|FILE_TXT,';',CP_UTF8)` / M5:242 `FileOpen("order_status",FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI,0,CP_UTF8)`。区切りの引数 `';'` は `FileWriteString` には効かない（行は `;` 区切りではない）。
- MQL5 はヘッジ口座（`ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`）以外では、CSV を書いた後に戻り、`order_status` を書かない。
- メール設定（`TERMINAL_EMAIL_ENABLED` かつ `MAIL_SUBJECT` が空でない）なら、同じ内容を `SendMail` でも送る。

行の形（EA の組み立て式。実値は書かない）:

```text
<EA名> 新規 #<ticket> <種別> <lots> <symbol>, 価格 <open> sl: <sl> tp: <tp>, 他: <n>
<EA名> 決済 #<ticket> <種別> <lots> <symbol> 価格 <open> → <close>, 損益: <p> 口座残高: <bal> <通貨>, 他: <n>   (MQL4)
<EA名> 決済 #<ticket> <種別> <lots> <symbol>, 価格 <open> → <close>, 損益: <p> 口座残高: <bal> <通貨>, 他: <n>  (MQL5)
```

- `<種別>`: MQL4 は `BUY` / `SELL` / `BUYLIMIT` / `SELLLIMIT` / `BUYSTOP` / `SELLSTOP` / `unknown`、MQL5 は `BUY` / `SELL` / `unknown`。
- `<lots>` `<p>` `<bal>` は小数 2 桁。価格（`<open>` `<close>` `<sl>` `<tp>`）は `dts2` で、10 未満なら 4 桁、以上なら 2 桁。
- `<EA名>`: magic が 0 なら `N/A`、入力 `magic_01`〜`magic_05` のどれかと一致すれば対応する `magic_0N_name`（既定 `noname`）、無ければ `EA<magic>`。
- `他: <n>`: 新規の行は保有中の総数 - 1、決済の行は保有中の総数（MQL4 の総数は待機注文を含む `OrdersTotal()`、MQL5 はポジション数）。
- 決済の行は履歴が取れた分だけ出る（MQL4 は `OrderSelect(...,MODE_HISTORY)` が成功したもの、MQL5 は open / close の deal が両方見つかったもの）。取りこぼしうる。

読み手 `check_order.sh`（内容は解釈しない）:

- `flock -n` で多重実行を防ぐ。前回の中断で残った `order_status.taking` を先に `order_status.pending` へ回収する。
- `order_status` を `order_status.taking` へ `mv` し、1 秒待って（EA が書き終えるのを待つ）`order_status.pending` へ追記する。EA は毎回ファイル名で開き直すので、`mv` 後の書き込みは新しい `order_status` に入る。
- `order_status.pending` を 4500 字未満のチャンクで LINE へ送り、受理されたチャンクだけ pending から消す。LINE が 400 で拒否したチャンクは `order_status.failed` へ退避して短い通知を送る。それ以外の失敗は pending に残し、次回再送する。
- テストでは `atst_test_make_order_status <name> <line>...` が任意の行を追記する。

## 互換の規則

#137 以降の変更が守るもの。

- **規則 a**: 列の追加は **末尾** のみ（列 9 以降）。途中への挿入・削除・並べ替えはしない。
- **規則 b**: 既存の列 1〜8 の意味・順序・単位・文字列化（書式）を変えない。
- **規則 c**: 既存の読み手の `NF >= 8` は据え置く（`NF >= 9` に変えない）。新しい列を使う読み手だけが `NF >= N` を要求する。
- **規則 d**: 古い読み手は列 9 以降を見ないので、末尾に列を足しても壊れない。新しい列は、読み手が無くても書いてよい。
- **規則 e**: 旧 EA の 8 列の行と新 EA の行が同じファイルに混在しうる（EA の更新前後、`truncate_monitoring.sh` が消すまで）。読み手は行ごとに `NF` を見る。
- **規則 f**: 列を増やす PR は、この文書の列表・`tests/test_helper.bash` の `atst_test_make_monitoring_csv`・この節を同じ PR で更新する。
- **規則 g**: EA からの直接通知（WebRequest）には移行しない（MT が固まると通知も止まり、外から見る価値を失うため）。

## 状態ファイルの予約（#137）

#137 では時系列ではない「今の状態」（接続・取引可否など）を別の状態ファイルで渡す形を予約したが、**#158 で状態ファイルは作らないことにした**。接続・取引可否・建玉数・証拠金維持率は CSV の末尾の列 9〜14 に毎回書き（[列表](#列表)）、`check_trade_ready.sh` が列 1 の時刻の窓で判定する。理由: 書き手の経路が 1 つで済み（`FileMove` による置き換えの実装と実機確認が要らない）、窓で「続いているか」を判定するには時系列が要り、旧 EA との混在も行ごとの `NF` で扱えるため。

- 第 1 段（EA を変えずに `check_tick.sh` が列 2 の窓内の変化で途絶を検知する）は #137 で実装済み。
- 第 2 段（`TerminalInfoInteger(TERMINAL_CONNECTED)` などを末尾の列 9〜14 に足し、`check_trade_ready.sh` で `TRADE_<MT>` を判定する）は #158 で実装済み。
- 将来、時系列に向かない状態を足すときは、改めて別ファイルを検討する（そのときは置き場を CSV と同じ `Files/` 直下、`KEY=VALUE` を 1 行 1 項目、一時ファイルから `FileMove` で置き換える、無い・KEY が無いときは「不明」、を出発点にする）。

## MQL4 と MQL5 の差

出力の列の順序と個数（14 列）は同じ。差は書き方と列 13 の意味だけ。

| 項目 | MQL4 | MQL5 |
|---|---|---|
| CSV の `FileOpen` | `FILE_READ\|FILE_WRITE\|FILE_TXT`、区切り 0、`CP_UTF8`（`FILE_ANSI` 無し） | `FILE_READ\|FILE_WRITE\|FILE_TXT\|FILE_ANSI`、区切り 0、コードページ指定なし |
| 列 1・2 の文字列化 | `(string)TimeGMT()` / `(string)TimeCurrent()` | `(string)(long)TimeGMT()` / `(string)(long)TimeCurrent()` |
| Bid / Ask の取得元 | 定義済み変数 `Bid` / `Ask` | `SymbolInfoTick(_Symbol,last_tick)` の `last_tick.bid` / `last_tick.ask` を同名のローカル変数へ |
| spread の関数 | `MarketInfo(Symbol(),MODE_SPREAD)` | `SymbolInfoInteger(Symbol(),SYMBOL_SPREAD)` |
| ping の関数 | `TerminalInfoInteger(TERMINAL_PING_LAST)` | 同じ |
| pip の書式と桁 | `DoubleToStr(.,4)`、`Digits()` | `DoubleToString(.,4)`、`_Digits` |
| 列 13（建玉数） | `OrdersTotal()`（待機注文を含む） | `PositionsTotal()`（ポジションだけ） |
| 列 14 の書式 | `DoubleToStr(.,2)` | `DoubleToString(.,2)` |
| `#property version` | 無し | `"1.10"`（#158 で 1.00 から） |
| `INTERVAL` | `extern int` | `input int` |
| テスターの判定 | `IsTesting()` | `MQL_TESTER`（`MQLInfoInteger(MQL_TESTER)` ではなく定数そのものを `if` に渡しており、常に真の疑い。K10） |
| `order_status` を書く条件 | 口座種別の条件なし（`OrdersTotal` / `OrderSelect`） | ヘッジ口座のときだけ（`PositionsTotal` / `PositionGetTicket`） |
| `order_status` の `FileOpen` | `FILE_READ\|FILE_WRITE\|FILE_TXT`、区切り `';'`、`CP_UTF8` | `FILE_READ\|FILE_WRITE\|FILE_TXT\|FILE_ANSI`、区切り 0、`CP_UTF8` |
| 決済の行の symbol の後 | 区切り無し（`<symbol> 価格`） | `, `（`<symbol>, 価格`） |

## 既知の不一致

文書化の過程で見つけた、揃っていない点・暗黙の前提。**ここでは直さずに記録する**。修正は別 Issue で行う。

| ID | 内容 | 影響 | 扱い |
|---|---|---|---|
| K1 | `truncate_monitoring.sh` だけ `NF >= 8` のガードと `tr -d '\r'` が無い | 書きかけの行・CR 付きの行も列 1 の比較だけで残る（他の読み手は無視するので現状は害が小さい） | 別 Issue 候補 |
| K2 | `check_price.sh` / `check_spread.sh` の全件走査は列 1 に `^[0-9]+$` を要求しない（`check_monitoring.sh` / `doctor.sh` は要求する） | 列 1 が数値でない行で `$1 > from` が文字列比較になりうる。実害は未検証 | 別 Issue 候補（低優先） |
| K3 | `draw_graph.sh` は列 1（UTC）に `3600*9` を固定で足す | グラフの時刻は常に JST。ホストや利用者の TZ に依らない | 別 Issue 候補 |
| K4 | 列 2（`TimeCurrent`）・列 4（`Ask`）は書かれるが読まれない。`atst_test_make_monitoring_csv` は列 2 を 0 で書く | #137 で列 2 を使うとき、テストの既定値が実態と合わない | #137 で解消（列 2 は `check_tick.sh` が読む。ヘルパは第 7 引数で列 2 を指定可。列 4 は引き続き読まれない） |
| K5 | `order_status` の決済の行で、symbol の後のカンマの有無が MQL4（M4:207）と MQL5（M5:224）で違う | 読み手は内容を解釈しないので実害なし | 別 Issue 候補（低優先） |
| K6 | `check_price.sh` の min/max の初期値が 10000 / 0 の番兵で、min が 10000 のまま、または max が 0 のままなら「データ無し」として終わる | 価格が 10000 以上の銘柄では値動きを判定しない | 別 Issue 候補 |
| K7 | CSV の `FileOpen` は MQL4 が `FILE_ANSI` / `FILE_UNICODE` 無しで `CP_UTF8`、MQL5 が `FILE_ANSI` で既定のコードページ | 出力のバイト列は実機で確認していない。読み手は 1 バイト文字の行として読む前提 | 別 Issue 候補（調査） |
| K8 | 列 3・4 の小数の桁数、MQL4 の列 5（`MarketInfo` は double）の書式は `(string)` のキャスト依存で、EA 間・MT4 / MT5 間で保証されない | 読み手は数値として比較するだけなので現状は影響なし（`report_image.sh` の要約は列 5 を文字列のまま表示する） | 記録のみ |
| K9 | `report_image.sh` のグラフ入力の awk は CR を除去しない（要約と列 8 は除去する） | 行末の列を読まないので現状は影響なし。列 8 を渡すように変えると効く | 記録のみ |
| K10 | MQL5 の `OnTick` / `OnInit` は `if(MQL_TESTER)`（M5:75 / M5:99）で判定しており、`MQLInfoInteger(MQL_TESTER)` ではない。定数は非 0 なので実運用でも条件が真になる疑い。実機未確認 | 真なら MT5 は `OnTimer` に加えティック契機でも行を書き、行間隔が `INTERVAL`（15 秒）より短くなりうる。列の順序・個数・単位には影響しない。「`tail -n 20` で約 5 分」は MT5 では短くなりうる | 別 Issue 候補（調査） |
| K11 | MQL5 は `SymbolInfoTick` の戻り値を見ない（M5:125） | 失敗時は列 3・4 が未定義（0 等）になりうる | 記録のみ |
| K12 | `check_trade_ready.sh` の完全な行の条件は `NF >= 14` なので、列 13 の後の `,` まで書かれて列 14 が未だの書きかけの行（`NF` 14、列 14 が空）も完全な行に数えうる | 列 9〜12 は書き終わっているので不良・良好の数え方は変わらない。表示・判定への影響なし | 記録のみ |
