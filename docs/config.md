# config の契約（atst）

`~/.atst/config`（設定）と `~/.atst/` の秘匿ファイル、導入スクリプトが受け取る環境変数の契約をまとめる。読み込みは `common.sh` が source する `lib/atst_config.sh`（秘匿ファイルの読み出しの一部は `lib/atst_line.sh`）が行うので、**読み込みの順序・失敗時の扱い・入力の経路を変える PR はこの文書を同じ PR で更新する**。各項目の既定値と説明の正は `templates/config` で、この文書は全変数の一覧を持たない。

通知（`alert_status`・スプール・LINE 送信）の契約は [docs/notification-pipeline.md](notification-pipeline.md)、テストでの config の上書きは [docs/testing.md](testing.md) にある。

## 目次

- [生成と読み込み](#生成と読み込み)
- [末尾に置く 3 項目](#末尾に置く-3-項目)
- [環境変数では渡せないもの](#環境変数では渡せないもの)
- [読み込みの失敗](#読み込みの失敗)
- [秘匿ファイル](#秘匿ファイル)
- [EA の自動配置（ATST_AUTO_ATTACH_EA）](#ea-の自動配置atst_auto_attach_ea)
- [X の起動待ちと自己修復の有効化（#140）](#x-の起動待ちと自己修復の有効化140)
- [導入スクリプトの入力（install_required_for_mt.sh）](#導入スクリプトの入力install_required_for_mtsh)
- [宣言形式（#134）](#宣言形式134)

## 生成と読み込み

- `~/.atst/config` が無ければ `templates/config` から初回生成する（`lib/atst_config.sh`）。以後は利用者のファイルで、既存の config に新しい行は自動では入らない。
- 全スクリプトは `common.sh` を source した時点で config を読み、`ATST_*` 変数で参照する。全行が [宣言形式](#宣言形式134) なら source せずに代入し、それ以外（現在の `templates/config` を含む旧形式）は従来どおり source する。
- config の source の直後に `atst_load_heartbeat_url` が外形監視の URL を決める（[秘匿ファイル](#秘匿ファイル)）。
- `ATST_ALERT_STATUS_FILE` / `ATST_CONFIG_DIR` が空のときの通知側の挙動は [docs/notification-pipeline.md](notification-pipeline.md#送信部と失敗の記録)。

## 末尾に置く 3 項目

- 監視対象は `ATST_TARGETS`（bash 配列。MT 名の前方一致）、毎分の監視の設定は `ATST_CHECK_TIMEOUT`（1 チェックの上限秒、既定 40）と `ATST_ORDER_CHECK_INTERVAL`（check_order の 2 回の間隔、既定 30）。
- この 3 項目は config の**末尾**に置く。引用符や括弧の閉じ忘れがあるとその行より後は読まれないため、末尾なら LINE の設定は読み込み済みで通知が届く。
- 既存利用者の config には自動では入らないので、未設定は `RUNNER_TARGETS_EMPTY` の通知で気付けるようにしてある（[docs/notification-pipeline.md](notification-pipeline.md#check_allsh-の回の流れ)）。
- `atst_has_targets` は `ATST_TARGETS` に 1 つ以上の要素があり空の要素が無いときに 0 を返す（未設定・`()`・`('')`・`('a' '')` は 1。スカラーは 1 要素とみなす。何も出力しない）。

## 環境変数では渡せないもの

- config の source の直前に `ATST_TARGETS` / `ATST_CHECK_TIMEOUT` / `ATST_ORDER_CHECK_INTERVAL` / `ATST_ALERT_REMIND_MINUTES` を unset する。これらは環境変数では渡せず、config だけが入力になる（手動実行やテストで環境に残った値が、既存利用者の config に無いことを隠さないため）。
- `ATST_NOTIFY_SPOOL`（`check_all.sh` の回のスプール）は逆に環境だけが入力で、source の前に退避して source 後に復元し、config に書いた値は捨てる（config に書くと、どのチェックも誰も送らないスプールに通知を溜めることになるため）。config で `readonly` にされると復元できないが、`atst_spool_dir` の検証を通らない値は使われず即時送信になる。通る値は実在する自分の `run.*` ディレクトリだけで、通常の運用では起きない（検証の条件は [docs/notification-pipeline.md](notification-pipeline.md#スプールcheck_allsh-の回)）。
- `WINEDLLOVERRIDES` は環境または config に既にある値（空も含む）を優先し、無ければ `mscoree=;mshtml=` を export する（cron からの wine 呼び出しで Wine-Mono / Wine-Gecko のダウンロード画面を出さないため）。
- テストで config の値を変えるときは `atst_test_set_config` を使う（[docs/testing.md](testing.md#test_helperbash-の関数)）。

## 読み込みの失敗

- config の source に失敗（引用符や括弧の閉じ忘れなど）するか、config の中に実行時に失敗した行（`=` の後の空白による `command not found`、失敗するコマンド置換など）があると、stderr に `[warn]` を 1 行出して続行する。bash 自身のメッセージ（ファイルと行）も stderr に残る。
- 構文エラーはその行で読み込みが止まり、実行時に失敗した行は飛ばして後の行を読む。
- 後者は source の間だけ張る ERR trap で検出し、呼び出し側の `set -e` と ERR trap は元に戻す（source は条件式の中に置かない。bash は条件式の中では ERR trap を実行しないため）。
- 呼び出し側に ERR trap があるとき（bats の test 本体など）は、それに触れず戻り値だけで判定する。この経路では実行時に失敗した行は検出されない（bats での確かめ方は [docs/testing.md](testing.md#err-trap-と-run-bash--c)）。
- 算術式の誤りは検出しない。
- config に `set -e` や ERR trap は書かない。

## 秘匿ファイル

- LINE トークン等の秘匿値は `~/.atst/.line_token` / `~/.atst/.line_id` / `~/.atst/.imgbb_key` / `~/.atst/.heartbeat_url`（リポジトリ外）に置き、config には書かない。
- `atst_load_heartbeat_url` は `~/.atst/.heartbeat_url` の 1 行目から空白・CR/LF を除いた値が空でなければそれ、無ければ config の `ATST_HEARTBEAT_URL` を外形監視の URL にする。出どころを `ATST_HEARTBEAT_URL_FROM`（`file` / `config` / 空）に入れる。export しない・何も出力しない（読めないときのエラーも出さない）・常に 0 を返す。
- `setup_heartbeat.sh` は外形監視の URL を対話式で `~/.atst/.heartbeat_url` に 600 で保存し、テストの ping を 1 回送る（GET。curl の終了コード 0 かつ 2xx で成功）。空行の入力で削除、EOF では何も変えない。`http(s)://` で始まらない値・空白や `"` `\` を含む値は保存しない。画面に URL は末尾 4 文字しか出さない。
- 画像ホストは ImgBB のみ。`atst_upload_image` は `~/.atst/.imgbb_key` が無ければ curl を呼ばず 1 を返す（キーの有無は `atst_has_imgbb_key`）。`report_image.sh` はキーがあるときだけグラフ画像を送り、さらに `ATST_IMAGE_REPORT_DESKTOP=1` ならデスクトップ画像も送る（既定は送らない。口座番号・残高が写るため）。
- `atst_mask_tail4 <value>` は 8 文字以上なら `****<末尾 4 文字>`、未満は `****` を出す（改行なし。`doctor.sh` / `setup_heartbeat.sh` が使う）。

## EA の自動配置（ATST_AUTO_ATTACH_EA）

- StartUp ini（#133）の規則は `lib/atst_mt.sh` の次の関数に集約し、ini を書くのは `mtctl.sh start` だけ。
  - `atst_auto_attach_enabled` — `ATST_AUTO_ATTACH_EA` が厳密に `1` のときだけ真。
  - `atst_startup_ini_path` — `<prefix>/drive_c/atst/startup_<小文字名>.ini`。
  - `atst_startup_ini_win_path` — `atst_to_win_path` で `C:\atst\...` にする（`winepath` を使わない）。
  - `atst_startup_ini_content` — CRLF 5 行。値が不正なら何も出さず 2（symbol）/ 3（period）/ 4（type）を返す。
  - `atst_startup_ini_arg` — terminal.exe に渡す引数。MT4 は素の `C:\atst\startup_<n>.ini`（MT4 は `/config:` を無視する。実機確認）、MT5 は `/config:C:\atst\...`。
- `mtctl.sh start` は `ATST_AUTO_ATTACH_EA=1` のとき ini（`drive_c/atst` は 700、ini は 600）を書いて `atst_startup_ini_arg` の 1 引数を付け、wine のログに `auto_attach: <その引数>` を書く。失敗・不正値は stderr に 1 行出して ini の引数無しで起動する（fail-open。値は出さない）。
- `doctor.sh` の `auto_attach` は、StartUp ini と、動いている MT に ini の引数（MT4 は素のパス、MT5 は `/config:`）が渡っているかを見る。

## X の起動待ちと自己修復の有効化（#140）

- `ATST_X_WAIT`（`mtctl.sh start` / `restart` が最初の MT の前に X のソケットを待つ上限秒。未設定・空は 120、`0` で待たない、0〜600 の 10 進以外は 120 にして stderr に 1 行）と `ATST_X11_DIR`（ソケットの置き場所、既定 `/tmp/.X11-unix`）は、環境変数でも `~/.atst/config` でも渡せる（`ATST_` で始まるので宣言形式でも受理される）。`templates/config` には書かない（切り分けとテスト用）。ディスプレイ番号は `DISPLAY` の最後の `:` の後ろから `.` の前まで。
- 自己修復（`self_heal.sh`）の有効化は `~/.atst/self_heal.enabled` の**存在**で、config のキーではない（`.heartbeat_url` と同じ「ファイルの存在 = 設定」）。自分の所有・mode 600 の通常ファイルのときだけ有効で、シンボリックリンク・他の所有者・他の mode は OFF（stderr に 1 行）。上限・クールダウン・対象キーは固定で、config・環境変数では変えられない。状態は `~/.atst/self_heal.log`（600）。猶予と `MONITORING_` のゲートには `ATST_MONITORING_THRESHOLD`（1〜99999 の 10 進以外は 180）を使う。
- `mtctl.sh` の MT ごとのロックは `~/.atst/mtctl_<フォルダ名の小文字。a-z 0-9 _ 以外は _>.lock`（600、1 行目は最後の起動の epoch）。パスは `atst_mt_lock_path`（`lib/atst_mt.sh`）だけが決める。

## 導入スクリプトの入力（install_required_for_mt.sh）

- VNC のパスワードは `~/.vnc/passwd` が無いときだけ作る。環境変数 `VNC_PASSWORD`（6〜8 文字。取り込み直後に unset し export しない。不正値は何も変える前に exit 1）があればそれ、無ければ `generate_vnc_password` の英数字 8 文字。`vncpasswd -f` へ stdin で渡し、umask 077 で作成する。
- 生成したパスワードは `verify_and_report` の結果表示に 1 回だけ出す（途中で止まって到達しなかった回は `on_exit` が未報告のときだけ 1 回出す。`VNC_PASS_REPORTED`）。ファイル・LINE・引数には出さない。
- MT インストーラは `$WINEPREFIX/drive_c/atst/installer/`（`prepare_mt_installer_dir`。700、どちらかの段がシンボリックリンクなら中止）に取得し、`wine start /unix` で起動する（`Z:` の有無に依らない）。
- `ATST_INSTALL_NO_ZDRIVE=1`（`1` のときだけ。他の非空値は warn して無効）で、`setup_wine` の直後に `dosdevices/z:` を消し（`remove_z_drive`。シンボリックリンクのときだけ、冪等、既存 prefix でも）、結果表示で不在を確認する。効果は「ドライブとして `/` が見えなくなる」だけで、`\\?\unix\` 形式など Wine の別経路は塞がない。隔離ではない緩和で、本筋は実行ユーザーの分離（2 ユーザー構成の例は [docs/MT_USER_SEPARATION.md](MT_USER_SEPARATION.md)。スクリプトは非対応）。既定は消さない。
- ファイル先頭の関数を試すための `ATST_INSTALL_SOURCE_ONLY=1` は [docs/testing.md](testing.md#関数だけを読み込むモード)。

## 宣言形式（#134）

- `atst_config_parse <file>`（`lib/atst_config.sh`）が bash の組み込みだけで 1 行ずつ判定する。**全行**が下の形なら新形式（`ATST_CONFIG_FORMAT=strict`）として、ファイル順に代入する（同じキーは後の行が勝つ。source も `eval` もしない）。1 行でも外れると旧形式（`legacy`）で何も代入せず、従来の source 経路で読む（行単位の部分適用はしない）。読めないファイルも旧形式（`ATST_CONFIG_FORMAT_LINE=0`）。
- 受理する行:
  - 空行・空白とタブだけの行、先頭（空白の後）が `#` の行（無視）。
  - `KEY=値`。値は `[A-Za-z0-9_./:@%+,=-]*`（空も可。`KEY=` は空文字列の代入で unset ではない）。
  - `KEY="値"`（中に `"` `\` `` ` `` `$` を含まない）、`KEY='値'`（中に `'` を含まない）。中身をそのまま代入する（展開・アンエスケープしない）。
  - `ATST_TARGETS=('a' "b")`（1 行。各要素は上の 2 つの引用形で空白区切り。`()` は空配列）。配列を受けるのは `ATST_TARGETS` だけで、スカラー形 `ATST_TARGETS=x` は拒否。
- 共通: `KEY` は `ATST_[A-Z0-9_]+` / `WINEPREFIX` / `WINEARCH` / `WINEDEBUG` / `WINEDLLOVERRIDES` / `DISPLAY`。ただし `ATST_HOME` / `ATST_TEMPLATES_DIR` / `ATST_CONFIG_DIR` / `ATST_CONFIG_FILE` / `ATST_NOTIFY_SPOOL` / `ATST_CONFIG_FORMAT` / `ATST_CONFIG_FORMAT_LINE` は拒否。`=` の前後に空白なし、値の後は末尾の空白・タブだけ（行末コメントは拒否）。CR を含む行は拒否。`$HOME` 等は展開されないので `WINEPREFIX` は絶対パスで書く。
- 新形式は bash の構文の部分集合なので、`bash -c '. config'` でも同じ値に読める。
- 結果は `ATST_CONFIG_FORMAT`（`strict` / `legacy`）と `ATST_CONFIG_FORMAT_LINE`（旧形式のとき最初に外れた行の番号、新形式は空）。どちらも export しない。パーサは何も出力しない（値は秘匿値のことがある）。
- 新形式でも、値は各スクリプトにそのまま渡る。数値の項目を算術式で使うスクリプトがあるので、数値の項目には数字だけを書く（値の型検証は後段の課題。読み込みの段階ではコマンドを実行しない）。
- `templates/config` がコードで決めていた値（`ATST_ALERT_STATUS_FILE`、`.line_token` / `.line_id` からの `ATST_LINE_TOKEN` / `ATST_LINE_ID`、`WINEPREFIX` / `WINEARCH` / `WINEDEBUG` / `DISPLAY` と後ろ 4 つの export）は `atst_config_defaults` が template と同じ式で、空のときだけ埋める。呼ぶのは新形式のときと、`ATST_CONFIG_DIR=` の行を持たない旧形式（新形式のつもりで 1 行書き損じた config。書き損じても通知が届くように）のとき。config を読めない（権限が無い等）ときも呼ぶ（行の判定ができないため、通知が届く側に倒す）。template のコードを含む旧形式では呼ばない（そのコードが決めた値のまま。途中で壊れて空なら空のまま、#110）。
- 旧形式のとき stderr には何も足さない。どちらの形式かは `doctor.sh` の `config` 行で見る（旧形式も NG にしない。値は表示せず、最初に外れた行の番号とキー名だけを出す）。
- `templates/config` の新形式への書き換えと source 経路の撤去は後段（#134 のスコープ外）。
