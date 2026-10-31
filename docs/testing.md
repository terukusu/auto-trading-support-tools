# テストと CI の契約（atst）

bats の自動テスト（`tests/`）、共通フィクスチャ `tests/test_helper.bash`、stub（`tests/stubs/`）、静的解析と CI（`.github/workflows/ci.yml`）の契約をまとめる。**ヘルパの関数・stub の変数・CI のジョブや対象ファイルを変える PR はこの文書を同じ PR で更新する**。検証コマンドそのもの（`bats` / `bash -n` / `shellcheck`）と「本番 VPS で試さない」規範は `CLAUDE.md`「実行・検証」にある。

テストで上書きする config の読み込み規則は [docs/config.md](config.md)、push の中身（1 push 5 メッセージなど）は [docs/notification-pipeline.md](notification-pipeline.md) にある。

## 目次

- [前提と実行](#前提と実行)
- [sandbox の規則](#sandbox-の規則)
- [test_helper.bash の関数](#test_helperbash-の関数)
- [stub](#stub)
- [ERR trap と run bash -c](#err-trap-と-run-bash--c)
- [関数だけを読み込むモード](#関数だけを読み込むモード)
- [bats 1.1.0 互換](#bats-110-互換)
- [静的解析](#静的解析)
- [CI](#ci)

## 前提と実行

- リポジトリ直下で `bats tests/`（unit。`tests/slow/` は含まれない）。CI と PR 前の最終確認は `bats tests/ tests/slow/`（両方）。
- 待ち・実プロセスを伴う遅いテストは `tests/slow/` に置く。`tests/slow/` のファイルは `load ../test_helper`、リポジトリは `$BATS_TEST_DIRNAME/../..`、stub は `$BATS_TEST_DIRNAME/../stubs` で参照する。
- bats は開発者向けの依存で、開発機に `sudo apt-get install bats` で入れる。VPS には不要で、`install_required_for_mt.sh` には入れない。vendoring / submodule もしない。
- `tests/` は開発者向けで、インストール経路からは参照しない。

## sandbox の規則

- テストは必ず `atst_test_setup_sandbox` の後に `common.sh` を読む／スクリプトを実行する。実 `~/.atst`・`~/.wine`・LINE・Wine に触れない。
- `check_*.sh` 等は source せず、サブプロセスで実行する。
- sandbox 内でのみ動くヘルパは、`HOME` が `$ATST_TEST_SANDBOX/home` かどうかで sandbox の中にいることを確かめる。

## test_helper.bash の関数

`load test_helper`（`tests/slow/` からは `load ../test_helper`）で読む。`ATST_TEST_DIR` は `tests/` の絶対パスで、ヘルパがリポジトリや `templates/config` を探すのに使う。

- `atst_test_setup_sandbox` — `mktemp -d` の sandbox（`ATST_TEST_SANDBOX`）に `HOME` / `WINEPREFIX` / `PATH`（先頭に `tests/stubs`）/ `ATST_TEST_CURL_LOG` を向ける。`ATST_PROC_ROOT` も sandbox 内の空ディレクトリ `proc/` に向けるので、既定では実プロセスは見えない。
- `atst_test_teardown_sandbox` — sandbox を削除する。
- `atst_test_make_mt <name> <MT4|MT5> [<appdata-hash>]` — 偽の MT インストールと AppData データフォルダ・`origin.txt` を作る。
- `atst_test_source_common` — sandbox 内でのみ `common.sh` を source する。
- `atst_test_make_monitoring_csv <name> <secs_ago> <bid> <spread> <pip> [<ping> [<time_server> [<extra>]]]` — MT4 の `MQL4/Files/terminal_monitoring.csv` に 8 列の行を 1 行追記する。`<ping>` は 6 列目（マイクロ秒、既定 12）、`<time_server>` は列 2（最後のティックのサーバー時刻。既定・空は 0 で、`check_tick.sh` は無視する）。`<extra>`（#158）が空でなければ `USDJPY` の後に `,<extra>` を足す（例 `1,1,1,1,0,0.00` で 14 列。検証しない）。列 13・14 を読むテスト（#177）は建玉数と証拠金維持率を入れた `1,1,1,1,2,150.00`（建玉 2 件、維持率 150.00%）で完全な行を作り、書きかけの行は列 14 を空にした `1,1,1,1,2,` で作る。それを読む `atst_monitoring_last_row` / `atst_positions_note` は `tests/positions_note.bats`、`check_margin.sh` は `tests/check_margin.bats` で試す。引数が 5〜8 個でなければ 1 を返して行を足さない。列の意味は [docs/monitoring-csv.md](monitoring-csv.md)。
- `atst_test_push_count` — `$ATST_TEST_CURL_LOG` に記録された LINE push の件数。ログが無ければ 0。
- `atst_test_make_order_status <name> <line>...` — MT4 の `MQL4/Files/order_status` に行を追記する。
- `atst_test_make_proc <pid> <uid> <environ> [<argv>...]` — `$ATST_PROC_ROOT/<pid>/` に偽の `cmdline` / `status` / `environ` を作る。`<uid>` は数値か `-`（= 自分の EUID）、`<environ>` は改行区切りの `KEY=VAL`、`-` なら environ を作らず、空文字なら空ファイル。sandbox 内でのみ動き、`ATST_PROC_ROOT` が sandbox 配下でなければ失敗する。
- `atst_test_fake_mt_process <name>` — `C:\Program Files\<name>\terminal.exe` に見える `sleep 30` を起動して pid を出力する（`ATST_TEST_FAKE_PID=$(atst_test_fake_mt_process ...)` の形で受け、teardown で kill 必須）。実プロセスを見るので、呼ぶ前に `export ATST_PROC_ROOT=/proc` が必要。実 MT と前方一致しない名前を使う。名前が固定のため `bats --jobs` など同一ホストでの並列実行は不可。
- `atst_test_set_config <KEY> <value>` — sandbox の `~/.atst/config`（無ければ `templates/config` のコピー）に `KEY=<value>` を追記して既定値を上書きする。config は実行のたびに読まれるので、環境変数では上書きできない。
- `atst_test_set_targets [<name>...]` — `ATST_TARGETS=(...)` を `%q` で引用して config に追記する。名前なしは `ATST_TARGETS=()`。未設定を試すときはテスト側で config の該当行を消す。
- `atst_test_make_runner_home` — リポジトリの `*.sh`・`lib/`・`templates/` を実行権限ごと sandbox の `atst/` にコピーしてそのパスを出力する。`check_all.sh` / `run_with_targets.sh` は隣のスクリプトを実行するので、コピー側のスクリプトを差し替えて試す。
- `atst_test_make_dummy_zip <zip_path> <top> [<install_body>]` — sandbox 内に GitHub archive 形の zip を作る。中身は `<top>/install_required_for_mt.sh`（既定は `$ATST_TEST_SANDBOX/marker` を作り `install.log` に 1 行追記）と `<top>/README.md`。sandbox 外・不正な `<top>` は return 1。
- `atst_test_stub_script <dir> <name> <mode>` — `<dir>/<name>` にスタブを書く。呼び出しを `$ATST_TEST_SANDBOX/calls.log` に記録し、mode は `record`（exit 0）/ `fail`（exit 3）/ `exit1` / `hang`（sleep 300）/ `hang_ignore_term`（TERM 無視）/ `slow`（3 秒）。`<dir>` は sandbox 内に限る。

## stub

- `tests/stubs/curl` — ネットワークに出ず、実 curl も呼ばず、引数を `$ATST_TEST_CURL_LOG` に 1 行で記録する。sandbox の外では何もしない。
  - `-H @<fd>` の Authorization は読まない（記録もしない）。
  - `-K <path>` があればそのファイルの `url` / `data` / `data-raw` 行だけを同じ記録行に ` | ` 区切りで付ける（`header` などの他の行は記録しない。1 回の呼び出しは 1 行のまま）。
  - 応答は `ATST_TEST_CURL_BODY` / `ATST_TEST_CURL_HTTP_CODE`（既定 200）/ `ATST_TEST_CURL_EXIT`（既定 0）で指定する。
  - `ATST_TEST_CURL_HTTP_CODE_SEQ`（空白区切りの HTTP コード列）を置くと、n 回目の呼び出し（`$ATST_TEST_CURL_LOG` の追記後の行数。quota・画像アップロードも数える）が n 番目のコードを返し、尽きたら `ATST_TEST_CURL_HTTP_CODE`。
  - `ATST_TEST_CURL_FILE` を置くと、別引数の `-o <path>` があり終了コードが 0 のとき、そのファイルを `<path>` にコピーして本文は出さない。
- `tests/stubs/winepath` — Wine を起動せずパスを `C:\...` 形式に変換する。`atst_find_pid` は使わないが、`mtctl.sh start` の経路が実 `winepath` を呼ぶため、実 Wine を起動しない安全網として残す。
- `mtctl.sh start` / `restart` を実際に動かすテストは、`ATST_X11_DIR` を sandbox のディレクトリに向け、待たないテストでは `ATST_X_WAIT=0` にする（開発機・CI の本物の `/tmp/.X11-unix` を見ない。既定のままだと最大 120 秒待つ）。wine は `atst_test_stub_script` の record スタブを `WINE` に置く（#140）。
- stub を足したら `ci.yml` の列挙も足す（[CI](#ci)）。

## ERR trap と run bash -c

- bats の test 本体は ERR trap を持つので、そこで `common.sh` を source すると config の実行時に失敗した行は検出されない（構文エラーと source 自体の失敗だけ検出）。理由は [docs/config.md](config.md#読み込みの失敗)。
- 実行時の失敗は `run bash -c` で確かめる（`tests/common.bats` の CF-02 / CF-03）。

## 関数だけを読み込むモード

- `install_required_for_mt.sh` のファイル先頭の `generate_vnc_password` / `vnc_password_ok` / `zdrive_opt_in` / `remove_z_drive` / `prepare_mt_installer_dir` は、`ATST_INSTALL_SOURCE_ONLY=1` で source したときだけ以降を読まずに返る（実行時は効かない。`tests/install_vnc_password.bats` / `tests/install_zdrive.bats` 用）。

## bats 1.1.0 互換

- bats の下限は 1.1.0（Ubuntu 20.04）。
- 使ってよいのは `@test`、`setup` / `teardown`、`load`、`run`、`$status` / `$output` / `${lines[@]}`、`skip`、`$BATS_TEST_DIRNAME`、`$BATS_TMPDIR` のみ。
- 1.2 以降の機能（`setup_file` / `teardown_file`、`$BATS_TEST_TMPDIR` / `$BATS_FILE_TMPDIR`、`run` のオプション、`bats_load_library` / `bats_require_minimum_version`）と bats-assert / bats-support は使わない（assertion は `[ ]` で書く）。

## 静的解析

- `shellcheck -S warning *.sh lib/*.sh` が 0 件を保つ。基準版は ShellCheck 0.11.0。
- 抑止するときは同じ行に理由コメントを書く。

## CI

- `.github/workflows/ci.yml` が PR（宛先ブランチを問わない）と master への push のたびに、GitHub ホステッドランナー `ubuntu-24.04` で 4 つを走らせる。
  - `bash -n` — `*.sh`・`lib/*.sh`・`scripts/*.sh`・`tests/test_helper.bash`・`tests/stubs/*`。
  - `shellcheck -S warning -f gcc` — `*.sh`・`lib/*.sh`・`scripts/*.sh`・`tests/test_helper.bash`・`tests/stubs/curl`・`tests/stubs/winepath`。stub を足したら ci.yml の列挙も足す。ShellCheck は [静的解析](#静的解析) の基準版を GitHub Releases から SHA256 を検証して入れる（apt 版は使わない）。
  - bats 1.1.0 互換 grep — [bats 1.1.0 互換](#bats-110-互換) で挙げた 1.2 以降の機能が `tests/` に無いこと。
  - `bats tests/ tests/slow/` — apt の bats。新しいテストが使う zip / unzip も apt で入れる。`--jobs` なし。
- ローカルで同じコマンドを打てば同じ結果になる。
- 失敗したテストは再試行しない。flaky なら Issue を起票し、件数を減らしたり assertion を弱めたりしない。
- ShellCheck・`actions/checkout`・ランナー image の版上げは ci.yml を変える PR で行う。
- required check にするかどうか（ブランチ保護）はリポジトリ設定で、ci.yml の外。
