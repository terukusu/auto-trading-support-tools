# CLAUDE.md

auto-trading-support-tools（以下 atst）で作業する際のオリエンテーション。詳細なレビュー基準は [`docs/CODING_GUIDELINES.md`](docs/CODING_GUIDELINES.md) を参照。

## プロジェクト概要

Linux + Wine + MetaTrader4/5（以下 MT4/5）で構成する **FX 自動売買サーバー** の構築・監視・LINE 通知を支援する **bash スクリプト群**。複数の MT4/5 をまとめて扱い、クラッシュ・再起動・値動き/スプレッド/Ping の異常を検知して管理者へ通知する。概要は `README.md`、導入手順は GitHub Wiki を参照。

> **最重要の前提**: 本番 = **稼働中の実弾（リアルマネー）自動売買 VPS**。自動売買において最悪の事態は「建玉が決済されないこと」。MT のプロセス・建玉・cron・監視を**停止/中断する操作は、ユーザーの明示承認なしに実行しない**。

## 構成（主要ファイルの役割）

- `common.sh` — 全スクリプトが source する共通ライブラリ。`atst_*` 関数と設定ロード。source 時に `eval $(atst_gen_mt_list)` で MT 一覧を検出し、グローバル配列 `mt_home/mt_data/mt_name/mt_type/mt_term` に展開する（`mt_data` は MQL4/MQL5 の Files・Experts がある MT のデータフォルダ。AppData 側か、無ければインストール先）。
- `install_required_for_mt.sh` — まっさらな VPS に GUI(VNC+wm2) / Wine / MT インストーラ一式を導入するメインスクリプト。
- `mtctl.sh` — 複数 MT の list/start/status/stop/monitor。
- `check_*.sh` — cron から定期実行される監視（reboot / process / order / ping / price / spread / monitoring / daily）。
- `wrapper.sh` — crontab の `TARGET`（MT 名の配列リテラル）を展開し、各 check スクリプトへ渡すラッパ。
- `setup_*.sh` — `setup_cron.sh`（cron 設定）、`setup_line.sh`（LINE トークン設定）、`setup_monitoring_ea.sh`（監視 EA 配置）。
- `report_image.sh` / `draw_graph.sh` — スプレッド/値動きのグラフとデスクトップ画像を LINE 通知。
- `sleep_random.sh` / `truncate_monitoring.sh` / `minimize_*.sh` / `purge_needless_packages.sh` — 補助。
- `templates/` — 配置用テンプレート（`config`、`crontab.txt`、`xstartup`、`vncserver@:1.service`、`font_replace.reg`、`ip_rules_v*.txt`）。
- `MQL4/` `MQL5/` — MT に組み込む監視 EA のソース。
- `tests/` — bats の自動テスト（`*.bats`）、共通フィクスチャ `test_helper.bash`、`stubs/`（curl / winepath）。開発者向けで、インストール経路からは参照しない。

設定は `~/.atst/config`（`templates/config` から初回生成）を source して `ATST_*` 変数で参照。LINE トークン等の秘匿値は `~/.atst/.line_token` / `~/.atst/.line_id`（リポジトリ外）。

## 対応環境

- ディストロ: Ubuntu 20.04 / 22.04 / 24.04、Debian 11 / 12 / 13（minimal 推奨）。現行版の実機検証済みは Ubuntu 24.04 / OpenVZ のみ（README に明記）。EOL 版（Ubuntu 14〜18 / Debian 8〜10 等）は非サポート。
- 仮想化: OpenVZ/Virtuozzo の格安 VPS 〜 KVM。カーネルは共有のことがある（OpenVZ ではカーネル入替・swap 作成不可）。
- ランタイム: bash（一部 bash 固有構文を使用）、Wine 10 系（WineHQ stable を apt で固定、新規 prefix は `WINEARCH=win64`。理由は `docs/adr/0001-wine10-pin-and-win64.md`）。

## 実行・検証

変更の検証は以下で行う。

- 自動テスト: リポジトリ直下で `bats tests/`。bats は開発者向けの依存で、開発機に `sudo apt-get install bats` で入れる（VPS には不要。`install_required_for_mt.sh` には入れない。vendoring / submodule もしない）。
  - `tests/test_helper.bash`（`load test_helper`）: `atst_test_setup_sandbox`（`mktemp -d` の sandbox に `HOME` / `WINEPREFIX` / `PATH`（先頭に `tests/stubs`）/ `ATST_TEST_CURL_LOG` を向ける）、`atst_test_teardown_sandbox`（sandbox 削除）、`atst_test_make_mt <name> <MT4|MT5> [<appdata-hash>]`（偽の MT インストールと AppData データフォルダ・`origin.txt`）、`atst_test_source_common`（sandbox 内でのみ `common.sh` を source）、`atst_test_make_monitoring_csv <name> <secs_ago> <bid> <spread> <pip>`（MT4 の `MQL4/Files/terminal_monitoring.csv` に 8 列の行を 1 行追記）、`atst_test_make_order_status <name> <line>...`（MT4 の `MQL4/Files/order_status` に行を追記）、`atst_test_fake_mt_process <name>`（`C:\Program Files\<name>\terminal.exe` に見える `sleep 30` を起動して pid を出力。teardown で kill 必須。実 MT と前方一致しない名前を使う。名前が固定のため `bats --jobs` など同一ホストでの並列実行は不可）、`atst_test_set_config <KEY> <value>`（sandbox の `~/.atst/config`（無ければ `templates/config` のコピー）に `KEY=<value>` を追記して既定値を上書き。config は実行のたびに読まれるので環境変数では上書きできない）。
  - `tests/stubs/curl`（ネットワークに出ず引数を `$ATST_TEST_CURL_LOG` に記録。`-H @<fd>` の Authorization は読まない。応答は `ATST_TEST_CURL_BODY` / `ATST_TEST_CURL_HTTP_CODE` / `ATST_TEST_CURL_EXIT` で指定）、`tests/stubs/winepath`（Wine を起動せずパスを `C:\...` 形式に変換）。
  - テストは必ず `atst_test_setup_sandbox` の後に `common.sh` を読む／スクリプトを実行する（実 `~/.atst`・`~/.wine`・LINE・Wine に触れない）。`check_*.sh` 等は source せずサブプロセスで実行する。
  - bats の下限は 1.1.0（Ubuntu 20.04）。使ってよいのは `@test`、`setup` / `teardown`、`load`、`run`、`$status` / `$output` / `${lines[@]}`、`skip`、`$BATS_TEST_DIRNAME`、`$BATS_TMPDIR` のみ。1.2 以降の機能（`setup_file` / `teardown_file`、`$BATS_TEST_TMPDIR` / `$BATS_FILE_TMPDIR`、`run` のオプション、`bats_load_library` / `bats_require_minimum_version`）と bats-assert / bats-support は使わない（assertion は `[ ]` で書く）。
- 構文チェック: `bash -n <script>.sh`（必須）。
- 静的解析: `shellcheck -S warning *.sh` が 0 件を保つ（基準版 ShellCheck 0.11.0。抑止するときは同じ行に理由コメントを書く）。
- CI: `.github/workflows/ci.yml` が PR（宛先ブランチを問わない）と master への push のたびに、GitHub ホステッドランナー `ubuntu-24.04` で 4 つを走らせる。`bash -n`（`*.sh`・`tests/test_helper.bash`・`tests/stubs/*`）、`shellcheck -S warning -f gcc`（同じ対象。ShellCheck 0.11.0 を GitHub Releases から SHA256 を検証して入れる。apt 版は使わない）、bats 1.1.0 互換 grep（上に挙げた 1.2 以降の機能が `tests/` に無いこと）、`bats tests/`（apt の bats。`--jobs` なし）。ローカルで同じコマンドを打てば同じ結果になる。失敗したテストは再試行しない（flaky なら Issue を起票し、件数を減らしたり assertion を弱めたりしない）。ShellCheck・`actions/checkout`・ランナー image の版上げは ci.yml を変える PR で行う。required check にするかどうか（ブランチ保護）はリポジトリ設定で、ci.yml の外。
- 実挙動の確認は **使い捨ての VPS、またはユーザーが指定した MT 非稼働・建玉なしの検証機**で行い、**稼働中の本番 VPS では試さない**（手順は implement-issue の Phase 5.5）。
- **master へのマージは公開リリース**（Wiki の gist が `archive/master.zip` を取得して実行する）。install / setup / templates / cron 経路の変更はマージ前に実機検証を通す。

## git / GitHub

- **コミット名義はこのリポジトリの既存履歴の作者に合わせる**（設定済み。`git log` の author と一致させる）。
- **gh は terukusu アカウントで実行**する。アカウント切替は per-project の `GH_CONFIG_DIR`（`.claude/settings.local.json` に設定。このファイルは**コミットしない**ので各自の環境に合わせる）で行い、スキル側で `gh auth switch` しない。push/fetch は `origin`（`teru.github.com` の SSH エイリアス経由）で terukusu として行う。
- 対象リポジトリ: `terukusu/auto-trading-support-tools`、デフォルトブランチ `master`。

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
