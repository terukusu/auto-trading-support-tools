# 通知パイプラインの契約（atst）

監視（`check_*.sh`）の判定結果が LINE 通知と `~/.atst/alert_status` に届くまでの契約をまとめる。状態・再通知・スプール・ロックは `lib/atst_notify.sh`（common.sh が source する）、LINE 送信と `line_error.log` は `lib/atst_line.sh`、回の流れは `check_all.sh`、外形監視は `heartbeat.sh` にあり、**通知の送り方・記録の仕方・順序・しきい値を変える PR はこの文書を同じ PR で更新する**。通知キーごとの運用者向けの確認・復旧手順は [docs/RUNBOOK.md](RUNBOOK.md)。

config の読み込み（`ATST_NOTIFY_SPOOL` の退避・復元、各項目の既定値）は [docs/config.md](config.md)、テストでの LINE push の数え方は [docs/testing.md](testing.md) にある。

## 目次

- [alert_status の意味と状態の更新](#alert_status-の意味と状態の更新)
- [継続異常の再通知](#継続異常の再通知)
- [通知関数の使い分け](#通知関数の使い分け)
- [スプール（check_all.sh の回）](#スプールcheck_allsh-の回)
- [flush の規則](#flush-の規則)
- [スプール無効時の経路](#スプール無効時の経路)
- [送信部と失敗の記録](#送信部と失敗の記録)
- [check_all.sh の回の流れ](#check_allsh-の回の流れ)
- [判定の規則と状態だけのキー](#判定の規則と状態だけのキー)
- [外形監視（heartbeat.sh）](#外形監視heartbeatsh)

## alert_status の意味と状態の更新

- `~/.atst/alert_status` は「LINE に送れた状態」。行は `キー,値,更新時刻(epoch)[,再通知の段階]`。
- `check_*.sh` は判定結果（verdict）を `atst_update_alert` に渡す。`atst_update_alert` は `atst_alert_transition` で送るべき通知を決め、送信に成功したときだけ状態を更新する。
- 失敗した回は記録せず、次の回に再送する。通知の文面は呼び出し側が持つ。
- 遷移の記録は `atst_set_alert_status`（行を `キー,値,現在時刻` の 3 列で置き換える）。

## 継続異常の再通知

- 遷移が無くても、`PROCESS_*` / `MONITORING_*` / `TICK_*` / `TRADE_*` / `RUNNER_STUCK`（`atst_alert_remind_is_target` の固定一覧）が verdict 1・状態 1 のまま、`alert_status` の 3 列目（発生を送れた時刻）から `ATST_ALERT_REMIND_MINUTES` の段階に達したら、達した最上位の段階だけ【発生】を【継続中 N 分 / H 時間】に置き換えた文面で 1 回送る。
- `ATST_ALERT_REMIND_MINUTES` は config の項目。既定 `30 120 720` 分、`""` で OFF、不正値は stderr に 1 行出して既定。
- 送れたら段階を `alert_status` の 4 列目に記録する（`キー,1,<epoch>,<段階>`）。`atst_set_alert_stage` が 3 列目を保って書き、遷移の記録 `atst_set_alert_status` で消える（次の発生は 1 段目から）。
- 判定は `atst_alert_remind_due`。ロック内・flush でも、遷移ではなく段階で再判定する。スプール項目の verdict は `1:remind=<段階>`。

## 通知関数の使い分け

- `atst_update_alert` — キー付きの通知（遷移と再通知）。スプール有効時は送らずスプールに追記する（[スプール](#スプールcheck_allsh-の回)）。
- `atst_notify_text` — キーの無い文面だけの通知（stdin が本文。`check_reboot.sh` の再起動検出）。スプール有効なら文面だけの項目として追記し、無効・追記失敗なら `atst_send_to_line` で即時に送る。文面だけの項目はキーが無く記録されないので、push が失敗すると再送されない（即時送信の失敗と同じ）。
- `atst_send_to_line` — どこでも常に即時の個別 push。`check_order.sh` の約定通知・`send_to_line.sh`・`check_daily.sh`・`report_image.sh` が使う。

## スプール（check_all.sh の回）

- **スプール有効時**（`check_all.sh` の回の中で `ATST_NOTIFY_SPOOL` が有効）は、遷移ありの通知と再通知（`1:remind=<段階>`）を即時に送らず、判定結果と文面をスプールに追記するだけにする。`atst_update_alert` は送信もロックも記録もしない。追記できなければ [スプール無効時の経路](#スプール無効時の経路) で即時に送る。
- 置き場は `~/.atst/check_all.spool/run.<epoch>.<pid>/`（700、項目は 600）。項目名は `<連番>.<ランダム>`。1 行目がキー、2 行目が verdict（`1` / `0` / 再通知の `1:remind=<1-3>` / 文面だけなら空）、3 行目以降が文面。
- `atst_spool_begin` / `atst_spool_flush <max_pushes>` / `atst_spool_end` は `check_all.sh` 専用。
- `ATST_NOTIFY_SPOOL` を設定・export するのは `atst_spool_begin` だけ（config に書いた値は使わない。[docs/config.md](config.md#環境変数では渡せないもの)）。
- 使うたびに `atst_spool_dir` で形式（`~/.atst/check_all.spool/run.<数字>.<数字>`）・存在・非シンボリックリンク（`check_all.spool` も）・自分の所有を検証し、外れれば即時送信に倒す。
- `atst_spool_begin` がスプールを作れないときも stderr に 1 行出して、その回の通知は個別の即時送信になる。

## flush の規則

- 同じキーは後勝ち。キー単位のロック（[スプール無効時の経路](#スプール無効時の経路) と同じ `atst_alert_lock_file`）の中で再判定する。
- 1 メッセージにつき `【ホスト名】` 1 つ + 文面を空行区切りで連結し、1 メッセージ 4900 字以内（通知の途中で切らない）・1 push 5 メッセージで送る。
- push が 200 のときだけ、含めたキーを記録する。失敗した push で止める。
- `max_pushes` を超えた分は送らず記録もしない。キー付きは次の回に再送される。
- キーのロックは flush 全体で 10 秒だけ待ち、取れないキーは次の回へ回す。

## スプール無効時の経路

- 対象は直接実行・スプールを作れない回。
- 遷移があるとき（または再通知が段階に達したとき）だけ、キー単位のロック（`~/.atst/alert_update.<key>.lock`。ファイル名は `atst_alert_lock_file`）の中で再判定してから送信・記録する。手で実行した check と `check_all.sh` が同じ遷移を同時に見ても、通知は 1 回になる。
- ロックを取れなければ stderr に 1 行出して次の回へ。ロックファイルを開けなければロック無しで送る。

## 送信部と失敗の記録

- 送信部は `atst_line_post`（push 1 回）と `atst_line_texts_payload`（1〜5 個の text を 1 push に）。
- `ATST_ALERT_STATUS_FILE` が空のとき、`atst_set_alert_status` は stdin を読まずファイルも作らず、stderr に 1 行出して 1 を返す。`atst_update_alert` と `atst_spool_flush` は状態付きの通知を送らず、stderr と `line_error.log` に `no_alert_status` を残して 1 を返す（記録できないまま送り続ける空撃ちを防ぐ）。
- `ATST_CONFIG_DIR` が空なら `atst_spool_begin` は stderr に 1 行出して 1 を返し、その回は個別の即時送信になる。
- `atst_line_send_failing <n>` は `line_error.log` の見出し行（`http=upload:` を除き、`no_alert_status` は含む）の末尾 n 件がそろい、その最古が 60 分以内なら 0 を返す（ファイルを変えない）。

## check_all.sh の回の流れ

- crontab の毎分の行は `check_all.sh` の 1 行だけ。固定の順で check_reboot → check_order → check_process / monitoring / tick / trade_ready / ping / price / spread → check_order（`ATST_ORDER_CHECK_INTERVAL` 秒後の 2 回目）→ heartbeat → self_heal（監視対象があるときだけ）を 1 回ずつ実行する（順次実行で同時多発を避ける）。
- MT 名は `ATST_TARGETS` から配列のまま渡す（eval 無し）。
- 各チェックは `timeout`（`ATST_CHECK_TIMEOUT` 秒、heartbeat は 60 秒、self_heal は 150 秒）で打ち切り、打ち切りは `RUNNER_TIMEOUT_*` で LINE に通知する。1 つが失敗しても残りは実行する。
- その回の通知は `atst_spool_begin`（flock 取得・`check_all.started` の後）〜 F1 `atst_spool_flush 2`（1 回目のチェック群と打ち切り通知の後、2 回目の check_order の前。最大 2 push）〜 2 回目の check_order・heartbeat・self_heal 〜 F2 `atst_spool_flush 1`（最大 1 push）〜 `atst_spool_end` の順で 1 通にまとめて送る（通常は 1 push、後から出た打ち切りか自己修復の通知があれば +1。約定通知は即時のまま）。
- `unset ATST_NOTIFY_SPOOL` を common.sh の source 直後に行い、継承値を使わない。このため `atst_spool_begin` より前の `RUNNER_STUCK` 発生（ロックを取れなかった側の回）は即時に個別送信になり、復帰（`atst_spool_begin` の直後）・`RUNNER_TARGETS_EMPTY`・`RUNNER_TIMEOUT_*` はスプールに入る。
- `flock -n` で多重起動しない。前の回が終わらず `stuck_after = 10 * cap + 975 + 155` 秒（cap は `ATST_CHECK_TIMEOUT`。155 は self_heal の 150 + KILL までの 5 秒。既定値で 1530 秒、約 26 分）以上止まっていれば `RUNNER_STUCK` を通知する。開始時刻は `~/.atst/check_all.started`。
- self_heal（`self_heal.sh`、#140）は opt-in の自己修復。`~/.atst/self_heal.enabled`（自分の所有・600 の通常ファイル）が無ければ alert_status も読まずに終わる。有効なら、F1 または前の回で【発生】が届いた（alert_status が 1 の）`PROCESS_<MT>` / `MONITORING_<MT>` だけを見て `mtctl.sh start` / `restart` を 1 回に 1 台まで呼び、`atst_notify_text` で【自己修復】を F2 に入れる（前に【発生】、後に【自己修復】）。alert_status には書かず（`SELF_HEAL_` キーは無い）、回数・クールダウン・停止通知済みは `~/.atst/self_heal.log` の行（`<epoch>,<MT>,<キー>,<op>,<begin|ok|fail|halt>`）で持つ。上限（24 時間に 3 回、固定）に達したら halt 行を先に書き、書けたときだけ【自己修復停止】を 1 通送る。`mtctl.sh` は wine を `setsid` で新しいセッションに起動するので、self_heal の打ち切り（プロセスグループへの TERM / KILL）で起動した MT は止まらない。
- `ATST_TARGETS` が未設定・空・読み込み不能なら `RUNNER_TARGETS_EMPTY` を通知し、MT 名を要するチェックは実行しない。
- 自分と子の stderr は common.sh の source 前に `command exec 2>>` で `~/.atst/log/check_all.log`（700/600）に追記し、回の先頭に START 行、子の非 0 終了とロック待ちで飛ばした回を 1 行ずつ書く。開けなければそのまま続行する（tee 等の中継は置かない）。

## 判定の規則と状態だけのキー

- `check_tick.sh`（#137）は監視 CSV の列 2（最後のティックのサーバー時刻）が、列 1 の時刻で切った `ATST_TICK_THRESHOLD` 秒（既定 600、60〜86400、不正値は stderr に固定文 1 行で 600）の窓で不変なら `TICK_<MT>` を発生にする（CSV 全体を awk で 1 パス。`tail -n` は使わない）。列の定義は [docs/monitoring-csv.md](monitoring-csv.md)。
- `check_tick.sh` が判定しない（verdict 空）のは、CSV の停止（`ATST_MONITORING_THRESHOLD`。`MONITORING_` が通知）・週末（列 1 の UTC で金 20:00〜月 00:00 を整数演算で判定、`ATST_TICK_WEEKEND_SKIP=0` で無効）・窓の外側に行が無い・窓の中の行の列 1 の間隔（窓内の最初の行は直前の窓外の行から）に `ATST_MONITORING_THRESHOLD` 秒以上の空白がある（MT / EA の再開直後）・列 2 が 0 の行。週末の判定は `atst_is_weekend_epoch`（common.sh。`check_trade_ready.sh` と共用）。
- `check_trade_ready.sh`（#158）は監視 CSV の列 9〜12（接続・端末の自動売買ボタン・口座の取引許可・口座の EA 取引許可）が、列 1 の時刻で切った `ATST_TRADE_READY_THRESHOLD` 秒（既定 300、60〜86400、不正値は stderr に固定文 1 行で 300）の窓の中の完全な行（14 列以上・列 1 が数値・列 9〜12 がそれぞれちょうど `0` か `1`）ですべて不良（どれかが 0）なら `TRADE_<MT>` を発生、すべて良好なら復帰、混在なら状態を保つ。理由は最後の完全な行から作り、列 9 が 0 のときは列 11・12 の理由を出さない（切断中の口座情報は当てにならない）。
- `check_trade_ready.sh` が判定しないのは、14 列の完全な行が無い（古い EA の 8 列だけ。stderr にも出さない）・CSV の停止・週末（`ATST_TRADE_READY_WEEKEND_SKIP=0` で無効）・窓の外側に完全な行が無い・窓の中に `ATST_MONITORING_THRESHOLD` 秒以上の空白がある（`check_tick.sh` と同じ規則。8 列の行は間隔にも窓外にも数えない）。
- `check_daily.sh` は quota が取れた回に `LINE_QUOTA`（8 割以上で 1、未満・上限なしで 0）を `atst_set_alert_status` で直接書く。LINE 通知の無い、heartbeat 用の状態だけのキー（P1 の例外）。
- `check_daily.sh` は `ATST_IMAGE_REPORT_DESKTOP` の行が無い旧 config に、デスクトップ画像の既定 OFF を `atst_update_alert IMAGE_REPORT_DEFAULT_CHANGED` で 1 度だけ案内する。
- `check_daily.sh` は外形監視の URL が未設定なら、稼働OK に「外形監視: 未設定」の 1 行を足す（この行のためだけには送らない）。
- `check_daily.sh` は crontab が旧形式か混在（`atst_crontab_form`）のとき、稼働OK に【注意】の行を足す（`quota_warning` と同じく送る理由になり、毎朝。#176 で期限と 1 度だけの案内 `CRONTAB_LEGACY_NOTICE` は撤去）。
- crontab の形の判定 `atst_crontab_form`（`crontab -l` を読む）/ `atst_crontab_form_of`（文字列を受け取る）は common.sh。呼ぶのは doctor.sh・check_daily.sh・setup_cron.sh だけで、監視・通知の経路からは呼ばない。

## 外形監視（heartbeat.sh）

- `check_all.sh` の最後に呼ばれる。URL（決め方は [docs/config.md](config.md#秘匿ファイル)）が未設定なら何もしない。
- `alert_status` の値 1 のキーのうち `PROCESS_` / `TARGET_` / `MONITORING_` / `TICK_` / `TRADE_` / `RUNNER_`（`RUNNER_TIMEOUT_HEARTBEAT` を除く）/ `LINE_` で始まるもの（許可リスト。ロックなしで読むだけ）と、`atst_line_send_failing`（N は `ATST_HEARTBEAT_LINE_FAIL_COUNT`、不正値・未設定は 3）が真なら `LINE_SEND_FAILED` を並べる。
- 並べたものが空なら `<URL>` に ping（GET）、空でなければ `<URL>/fail` に POST する（本文はキー名だけ、`[A-Za-z0-9_ ]` 以外は `_`、1000 字まで）。
- URL と本文は `curl -K` のプロセス置換で渡し、argv に載せない（`ps` で見えないように。URL を知っていれば誰でも生存を報告できる）。
- curl の stderr は捨て、失敗時は URL を含まない 1 行を出して curl の終了コードで終わる。
- 空白・`"`・`\` を含む URL は送らず exit 1。
