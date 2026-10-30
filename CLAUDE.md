# CLAUDE.md

auto-trading-support-tools（以下 atst）で作業する際のオリエンテーション。詳細なレビュー基準は [`docs/CODING_GUIDELINES.md`](docs/CODING_GUIDELINES.md) を参照。文書の一覧と、それぞれが何の正本かは「ドキュメントの索引」。

## プロジェクト概要

Linux + Wine + MetaTrader4/5（以下 MT4/5）で構成する **FX 自動売買サーバー** の構築・監視・LINE 通知を支援する **bash スクリプト群**。複数の MT4/5 をまとめて扱い、クラッシュ・再起動・値動き/スプレッド/Ping の異常を検知して管理者へ通知する。概要は `README.md`、導入手順は GitHub Wiki を参照。

> **最重要の前提**: 本番 = **稼働中の実弾（リアルマネー）自動売買 VPS**。自動売買において最悪の事態は「建玉が決済されないこと」。MT のプロセス・建玉・cron・監視を**停止/中断する操作は、ユーザーの明示承認なしに実行しない**。

## ドキュメントの索引

利用者・運用者向け:

- [README.md](README.md) — 概要・導入の入口・運用（利用者向け、です・ます調）。
- GitHub Wiki — 導入手順の正本（別リポジトリ。clone の仕方は「作業の進め方」）。
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — 運用者向けの手順書。LINE の通知キーごとの確認・安全な復旧手順、MT の固まりの切り分け、VNC の罠、秘匿値の扱い。通知キー・通知文・確認コマンドを変えたら合わせて直す（各節のアンカー `key-*` は通知文からのリンク先として固定）。
- [docs/MT_USER_SEPARATION.md](docs/MT_USER_SEPARATION.md) — MT 実行ユーザーを管理ユーザーと分ける 2 ユーザー構成の「未検証の構成例」（新規導入のみ。install は非対応）と `Z:` 撤去（`ATST_INSTALL_NO_ZDRIVE=1`）の位置づけ。

開発の契約（挙動を変える PR は該当する文書を同じ PR で直す）:

- [docs/CODING_GUIDELINES.md](docs/CODING_GUIDELINES.md) — レビュー基準。
- [docs/notification-pipeline.md](docs/notification-pipeline.md) — alert_status・再通知・スプール・LINE 送信、`check_all.sh` の回、外形監視。
- [docs/config.md](docs/config.md) — `~/.atst/config` の読み込みと失敗、秘匿ファイル、EA の自動配置、導入の入力。
- [docs/testing.md](docs/testing.md) — bats の前提、`tests/test_helper.bash` と stub、bats の互換、静的解析、CI。
- [docs/monitoring-csv.md](docs/monitoring-csv.md) — 監視 EA が書く CSV と `order_status` の列契約。
- [docs/RELEASE.md](docs/RELEASE.md) — リリース（tag・gist 更新）の手順。
- [docs/adr/](docs/adr/) — 設計判断の記録（ADR）。

## 構成（主要ファイルの役割）

### 共通ライブラリ

- `common.sh` — 全スクリプトが source する共通ライブラリ。`atst_*` 関数と設定ロード。source 時に `atst_load_mt_list` で MT 一覧を検出し、グローバル配列 `mt_home/mt_data/mt_name/mt_type/mt_term` へ直接読み込む（フォルダ名をシェルコードとして評価しない。再呼び出しで再読込できる。`mt_data` は MQL4/MQL5 の Files・Experts がある MT のデータフォルダ。決め方は `docs/monitoring-csv.md`）。
- MT プロセスの特定（`atst_find_pid`）は `/proc`（`ATST_PROC_ROOT` で差し替え可）を自ユーザー分だけ走査し、`winepath`・`ps` を使わない（argv[0]（wine loader なら argv[1]）が terminal.exe のパスそのもの、またはパス + 空白 + 後続（Wine が StartUp ini の引数などを連結して見せる形。後続は無視）なら一致）。
- `lib/` — common.sh が source する内部ファイル（呼び出し側は common.sh だけを source する。単独で source しない）。`atst_config.sh`（~/.atst/config の生成・読み込み、KEY=VALUE 形式のパーサ `atst_config_parse`、`atst_load_heartbeat_url`、WINEDLLOVERRIDES）、`atst_line.sh`（文字列ヘルパ・ImgBB・LINE 送信・line_error.log・`atst_line_send_failing`）、`atst_mt.sh`（MT 検出・pid・StartUp ini・MQL / 監視 CSV のパス・走査）。

設定は `~/.atst/config`（`templates/config` から初回生成）を読んで `ATST_*` 変数で参照し（全行が KEY=VALUE 形式なら `atst_config_parse` が source せずに代入、それ以外は従来どおり source）、LINE トークン等の秘匿値は `~/.atst/` の別ファイル（リポジトリ外）に置く。契約は `docs/config.md`。

### 導入と設定

- `install_required_for_mt.sh` — まっさらな VPS に GUI(VNC+wm2) / Wine / MT インストーラ一式を導入するメインスクリプト。VNC パスワードの作り方・MT インストーラの置き場・`Z:` の撤去の規則は `docs/config.md`。
- `setup_*.sh` — `setup_heartbeat.sh`（外形監視の URL を `~/.atst/.heartbeat_url` に保存。保存の規則は `docs/config.md`）、`setup_cron.sh`（cron 設定。atst の行がある crontab には追記しない、EOF では変更しない。登録・移行案内・終了コードは README）、`setup_line.sh`（LINE トークン設定）、`setup_monitoring_ea.sh`（監視 EA 配置）、`setup_iptables.sh`（`templates/ip_rules_v4.txt`（`--v6` で v6）の `%%SSH_PORT%%` を `--port`（既定 22）で置換して stdout に出すだけ。適用・sudo・ファイル書き込みなし。common.sh を読まない。引数不正は exit 1、テンプレート異常は stdout 空で exit 2。警告・適用手順の案内は stderr）。

### MT の操作・診断・手動の補助

- `mtctl.sh` — 複数 MT の list/start/status/stop/monitor。メッセージに使用中の WINEPREFIX を ` (WINEPREFIX=...)` で付ける（`-q` は無出力のまま）。`ATST_AUTO_ATTACH_EA=1` のときの start（StartUp ini）は `docs/config.md`。
- `doctor.sh` — 読み取り専用の自己診断（wine / prefix / ATST_TARGETS / EA・CSV / crontab 形式 / 秘匿ファイル権限 / 外形監視・`check_all.log` の末尾・`auto_attach` を OK・NG・-- で表示。何も変更しない。各項目の判定は README）。
- `snap.sh` — VNC デスクトップ (:1) を `vncsnapshot` で 1 枚撮って `~/.atst/snap/` に保存し、絶対パスだけを stdout に出す（スマホから ssh / scp で見る用。手動実行のみで cron には無い）。削除はそのディレクトリ直下の日時名の通常ファイルだけで、いま撮ったものは消さない。`~/.atst/snap` がシンボリックリンクなら撮らない。`--line` は `atst_send_to_line` で 1 push。`[error]` / `[notice]` は stderr。保持枚数・権限・終了コードは README。

### 毎分の監視

- `check_all.sh` — crontab の毎分の行はこの 1 行だけ。固定の順で各チェックを 1 回ずつ順次実行し（同時多発を避ける）、その回の通知を 1 通にまとめる。実行順・打ち切り・`RUNNER_*`・ログは `docs/notification-pipeline.md`。
- `check_*.sh` — 監視（reboot / process / order / ping / price / spread / monitoring / tick / daily）。毎分のものは `check_all.sh` が実行する。`check_tick.sh` の判定と `check_daily.sh` の状態だけのキーは `docs/notification-pipeline.md`。
- `heartbeat.sh` — 外形監視（`check_all.sh` の最後、または旧形式の crontab の行）。URL 未設定なら何もしない。送る内容は `docs/notification-pipeline.md`。

### 毎分以外のジョブと旧形式

- `run_with_targets.sh` — 毎分以外のジョブ（`mtctl.sh` / `truncate_monitoring.sh` / `report_image.sh` の固定 3 本のみ）に `ATST_TARGETS` の MT 名を付けて起動する（`exec`、eval 無し）。監視対象が無ければ実行せず stderr に出して非 0 終了。
- `report_image.sh` / `draw_graph.sh` — 値動き/スプレッドの文字要約を LINE 通知。ImgBB の API キーがあるときだけグラフ画像、さらに `ATST_IMAGE_REPORT_DESKTOP=1` ならデスクトップ画像も（既定は送らない。口座番号・残高が写るため）。画像ホストとキーの規則・旧 config への案内は `docs/config.md`。
- `wrapper.sh` — 旧形式の crontab（`TARGET="(...)"` と `wrapper.sh "$TARGET" <script>`）が動き続けるためだけに残している。第 1 引数（MT 名の配列リテラル）を `eval` で展開して各スクリプトへ渡す。新しい crontab では使わない。
- `sleep_random.sh`（旧形式の crontab の行用。新形式の `check_all.sh` は順次実行なので使わない）/ `truncate_monitoring.sh`（監視 CSV・wine ログ・`check_all.log` の切り詰め）/ `minimize_*.sh` / `purge_needless_packages.sh` — 補助。

### 配布・テンプレート

- `scripts/` — 配布・リリース用（common.sh を source しない）。`init_atst.sh` は配布用で gist と同一内容（固定 tag の zip を sha256 照合して `./auto-trading-support-tools-master/` に展開し install を実行。`--channel master` は未検証で最新 master）、`release.sh` は tag 作成と `init_atst.sh` の書き換え。手順と規則は `docs/RELEASE.md`。
- `templates/` — 配置用テンプレート（`config`、`crontab.txt`、`xstartup`、`vncserver@:1.service`、`font_replace.reg`、`ip_rules_v*.txt`（sshd のポートは `%%SSH_PORT%%`、80/443 の行はコメントアウト。先頭の `#` 行に置換と適用の注意））。

### EA とテスト

- `MQL4/` `MQL5/` — MT に組み込む監視 EA のソース。書き出す CSV（`terminal_monitoring.csv`）と `order_status` の契約は [`docs/monitoring-csv.md`](docs/monitoring-csv.md)。
- `tests/` — bats の自動テスト（`*.bats`。待ち・実プロセスを伴う遅いものは `tests/slow/`）、共通フィクスチャ `test_helper.bash`、`stubs/`（curl / winepath）。開発者向けで、インストール経路からは参照しない。関数・stub・CI の内訳は `docs/testing.md`。

## 対応環境

- ディストロ: Ubuntu 20.04 / 22.04 / 24.04、Debian 11 / 12 / 13（minimal 推奨）。現行版の実機検証済みは Ubuntu 24.04 / OpenVZ のみ（README に明記）。EOL 版（Ubuntu 14〜18 / Debian 8〜10 等）は非サポート。
- 仮想化: OpenVZ/Virtuozzo の格安 VPS 〜 KVM。カーネルは共有のことがある（OpenVZ ではカーネル入替・swap 作成不可）。
- ランタイム: bash（一部 bash 固有構文を使用）、Wine 10 系（WineHQ stable を apt で固定、新規 prefix は `WINEARCH=win64`。理由は `docs/adr/0001-wine10-pin-and-win64.md`）。

## 実行・検証

変更の検証は以下で行う。

- 自動テスト: リポジトリ直下で `bats tests/`（unit。`tests/slow/` は含まれない）。CI と PR 前の最終確認は `bats tests/ tests/slow/`（両方）。bats は開発機だけに入れる（VPS・`install_required_for_mt.sh` には入れない）。前提・ヘルパ・stub は `docs/testing.md`。
- テストは必ず `atst_test_setup_sandbox` の後に `common.sh` を読む／スクリプトを実行する（実 `~/.atst`・`~/.wine`・LINE・Wine に触れない）。`check_*.sh` 等は source せずサブプロセスで実行する。
- bats は下限 1.1.0（Ubuntu 20.04）の互換範囲で書く。使ってよい機能・使わない機能は `docs/testing.md`。

- 構文チェック: `bash -n <script>.sh`（必須）。
- 静的解析: `shellcheck -S warning *.sh lib/*.sh` が 0 件を保つ（基準版と抑止の書き方は `docs/testing.md`）。
- CI: `.github/workflows/ci.yml` が PR と master への push のたびに上と同じコマンドを走らせる。ローカルで同じコマンドを打てば同じ結果になる。失敗したテストは再試行しない（ジョブの内訳・flaky の扱い・版上げは `docs/testing.md`）。

- 実挙動の確認は **使い捨ての VPS、またはユーザーが指定した MT 非稼働・建玉なしの検証機**で行い、**稼働中の本番 VPS では試さない**（手順は implement-issue の Phase 5.5）。
- **配布は tag 単位**。新規導入/再導入で使われるのは gist（= master の `scripts/init_atst.sh` と同一内容）が sha256 付きで指す tag の zip で、master へのマージだけでは配布されない（`--channel master` を明示した利用者を除く）。リリースは `scripts/release.sh`、gist 更新を含む手順は `docs/RELEASE.md`。install / setup / templates / cron 経路の変更は従来どおりマージ前に実機検証を通す（次のリリースで配布され、`--channel master` 利用者には即時に届く）。

## git / GitHub

- **コミット名義はこのリポジトリの既存履歴の作者に合わせる**（設定済み。`git log` の author と一致させる）。
- **gh は terukusu アカウントで実行**する。アカウント切替は per-project の `GH_CONFIG_DIR`（`.claude/settings.local.json` に設定。このファイルは**コミットしない**ので各自の環境に合わせる）で行い、スキル側で `gh auth switch` しない。push/fetch は `origin`（`teru.github.com` の SSH エイリアス経由）で terukusu として行う。
- 対象リポジトリ: `terukusu/auto-trading-support-tools`、デフォルトブランチ `master`。
- tag は `scripts/release.sh` でのみ打つ（3 要素 `vX.Y.Z`）。手順は `docs/RELEASE.md`。

## コミット衛生（公開リポジトリ）

このリポジトリは **公開（PUBLIC）**。コミット内容も Issue / PR 本文も誰でも読める。

**置かないもの**（コミットにも Issue / PR 本文にも入れない）:

- LINE 通知トークン・ユーザー/グループ ID、`~/.atst/.line_token`・`.line_id` の中身、各種アクセストークン・署名付き URL・鍵
- `auth.txt` 等の共通パスワード、`.claude/settings.local.json`（個人アカウント切替）
- スキルの作業用ファイル（`.claude/handoff/`、`.claude/worktrees/`、一時ディレクトリ）
- 個人アカウントに結び付く情報（メールアドレス、別組織のアカウント名、ホームディレクトリの絶対パス）
- ログ・コマンド出力の生貼り（必要なら件数・要約・該当行の抜粋にする）

コミット前に `git status --porcelain` で上記が含まれないことを確認し、`git add -A` / `git add .` は使わず**個別に `git add`** する。

## 作業の進め方

- 変更は Issue 駆動。計画は `.claude/skills/` の create-epic / create-issue、実装は implement-issue / implement-issue-lite / implement-epic を使う。
- 本番 VPS を変える操作（MT の start/stop、cron 設定、`apt` 実行、鍵・リポジトリ追加、ロケール/TZ 変更、swap 変更）は Issue ごとに**毎回ユーザー承認を得る**。委任不可。
- PR の master マージ承認の委任条件と stacked PR の扱いは、`.claude/skills/implement-issue/SKILL.md` の「マージ運用」節を正とする。
- 導入手順の正本は GitHub Wiki（別リポジトリ）。手順に影響する変更では、リポジトリの外に `git clone https://github.com/terukusu/auto-trading-support-tools.wiki.git` して参照する（clone はコミットしない。Wiki への書き込みは別途）。
