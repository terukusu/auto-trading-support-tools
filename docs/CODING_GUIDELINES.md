# Coding Guidelines (atst)

auto-trading-support-tools（bash + Wine + MetaTrader4/5 の自動売買サーバー構築・監視ツール群）のコーディング規約兼 **レビュー基準**。

## このドキュメントの読み方

- 目的は **レビューが機械的に照合できること**。各原則は「違反を具体的に指摘できる」粒度で書く。抽象的な心構えは最小限。
- 構成: **第I部 設計思想（Why）** → **第II部 原則（What: レビューチェックリスト）** → **第III部 具体パターン（How）** → **付録: レビュアーペルソナ / レビュー運用フロー / 最終チェックリスト**。
- レビュー時は第II部の各原則 ID（P1〜P15）で指摘する。例: 「P3 違反: `$var` が未クォート」。
- **最優先の価値基準**: ① 実弾本番の安全性（建玉・MT を壊さない）> ② 冪等性・無人実行の堅牢性 > ③ 秘匿情報の保護 > ④ 可搬性 > ⑤ 可読性。トレードオフはこの順で判断する。

---

# 第I部: 設計思想 (Why)

## 1. 本番は実弾。停止=損失になりうる

監視対象は**リアルマネーで動いている MT**。スクリプトのバグが「建玉が決済されない」「監視が黙って止まる」を招くと金銭損失に直結する。したがって atst のコードは、**落ちるより誤検知の方がまし／黙って止まるのが最悪**という価値観で書く。監視スクリプトは「自分が動かなくなったこと」自体も検知・通知できる設計（`check_monitoring.sh` / `check_process.sh`）を壊さない。

## 2. 無人・冪等が前提

ほぼ全スクリプトは cron から無人で、同一環境で何度も再実行される。「人が見ていれば気づく」前提のコードは書かない。インストール/セットアップ系は**途中から再実行しても壊れない（冪等）**こと、監視系は**ブロッキングなプロンプトや無限待ちを絶対に作らない**ことが設計の中心。

## 3. 枯れた最小構成を好む

対象は格安 VPS（メモリ 0.5〜2GB、OpenVZ 共有カーネル）。派手な依存より、枯れて軽量で確実に動くものを選ぶ（VNC + wm2、素の bash、`curl`）。新しい依存の追加は「本当に要るか」「全対応ディストロに在るか」を必ず問う。

## 4. 共通処理は common.sh に寄せる

全スクリプトは `common.sh` を source し、`atst_*` 関数・`ATST_*` 変数を使う。ロジックの重複を見つけたら `common.sh` の関数化を検討する（ただし 3 回ルール: 2 回目までは重複を許容し、3 回目で抽象化）。`common.sh` は内部で `lib/atst_config.sh` / `atst_line.sh` / `atst_mt.sh` / `atst_notify.sh` を source する。呼び出し側は `common.sh` だけを source し、`lib/*.sh` を直接 source しない。

---

# 第II部: 原則 (What) — レビューチェックリスト

各原則は「観察可能な違反」を伴う。レビューはコード上の該当箇所を示して指摘する。

**重大度の判定基準**（レンジ表記「block〜warn」はこの基準で確定する）: 違反が **① 実弾本番の安全性（MT/建玉/cron/apt/reboot）② 外部入力由来のインジェクション ③ 無人実行のハング/プロンプト ④ 秘匿情報の漏洩 ⑤ リモート到達性の喪失（sshd 停止等）⑥ 失敗を成功と表示する偽装** のいずれかに直結するなら **block**、それ以外（可読性・様式・軽微な堅牢性）は **warn**。

## P1. 本番安全性（最優先・block）

- MT プロセスの停止 (`mtctl.sh stop`, `kill`)、建玉に影響する操作、`sudo reboot`、cron の無効化/書き換え、`apt` 実行、リポジトリ/鍵の追加、ロケール/TZ 変更を**新規に自動実行**するコードは、承認フロー無しなら **block**。
  - 例外: opt-in の自己修復（#140、`self_heal.sh`）。`~/.atst/self_heal.enabled` があるときだけ、`check_all.sh` の回の中で `mtctl.sh start` / `mtctl.sh restart` を呼ぶ。既定 OFF・対象キーの限定・回数上限・クールダウン・LINE 通知のいずれかを外す変更、`check_all.sh` 以外から `self_heal.sh` を呼ぶ経路の追加、`mtctl.sh` の MT 単位ロックを外す変更、および上限到達後も動かす変更は block。
- 監視スクリプトが異常時に**通知せず握りつぶす**経路があれば block（例: エラーで `return 0` して無通知）。
- 「監視が止まったこと自体の検知」(`check_monitoring.sh`, `check_process.sh`) を実質無効化する変更は block。
- 状態を持つ異常通知（発生/復帰を `~/.atst/alert_status` で重複抑止するもの）は、`check_*.sh` に `atst_set_alert_status` と送信を個別に書かず `atst_update_alert` を使う（送信成功時だけ状態を更新し、失敗した回は次回に再送する。判定〜送信〜記録はキー単位のロックで直列化され、同じ遷移を複数のプロセスが同時に見ても通知は 1 回になる）。`check_all.sh` の回の中（`ATST_NOTIFY_SPOOL` が有効）では、`atst_update_alert` は送信も記録もせずスプールに追記するだけで、回の途中と最後の `atst_spool_flush` が 1 通にまとめて送り、push が 200 のときだけキーを記録する（記録は送信成功後のみ、の契約は変わらない）。自前で状態だけ先に更新して通知を取りこぼす実装は block。
- 破壊的コマンド（`rm -rf`, `sed -i`, `>` リダイレクト, `truncate`）の対象が**変数展開**で、その変数が空になりうる経路があれば block（`rm -rf "$DIR/"` で `$DIR` が空だと `/` を掃く）。

## P2. 冪等性（install/setup 系・block〜warn）

- インストール/セットアップ処理は**再実行安全**であること。追記 (`>>`, `cat >> crontab`)、リポジトリ追加、鍵配置、`/etc/fstab` や `user.reg` への書き込みは、**既存チェック無しの無条件追記を block**（重複行・多重登録を生む）。
  - 既存の良い例: `common.sh` の config 生成は `[ ! -e ]` ガード、`install_required_for_mt.sh` の crontab 追記は `grep` で既存確認してから追加。
- 冪等化の手段は「存在チェックしてから書く」「`install -D`」「`grep -q` してから追記」など。レビューはガードの有無を確認する。

## P3. クォートと word splitting（block〜warn）

- 変数・コマンド置換の展開は原則ダブルクォートする: `"$var"`, `"$(cmd)"`, `"${arr[@]}"`。未クォートで word splitting / glob 展開が起きうる箇所は warn、パスやユーザー入力なら block。
- `[ -e $x ]` のような test 内の未クォートは block（`$x` が空/空白で構文崩壊）。
- 配列は `"${arr[@]}"`（`$arr` や `${arr[*]}` の誤用を指摘）。
- 例外: 意図的に分割させたい箇所（例: `$target_cmd` をコマンド+引数に割る）はコメントで意図を明示していれば可。

## P4. エラーハンドリングと終了ステータス（block〜warn）

- `atst` の慣習は `set -e` に頼らず**明示的に失敗を扱う**（監視系は 1 コマンドの失敗で全体を落としたくないため）。インストール系の「失敗したら止めるべき直列処理」は P13 に従う。
- `cmd1 | cmd2` の **cmd1 の失敗が握りつぶされる**箇所（パイプ先頭の失敗検知が必要なのに未対応）は warn。
- `foo=$(cmd); if [ $? ... ]` の間に別コマンドを挟んで `$?` を汚す誤りは block。
- 終了状態が使われる位置（関数・スクリプトの最後のコマンドなど）で、加算に `let i++` / `(( i++ ))` を使うのは block（式の値が 0 のとき終了状態が 1 になり、終了コードを壊す）。`i=$((i + 1))` を使う。それ以外の位置の `let` は warn にとどめる（#101）。
- 「失敗時は通知する／安全側に倒す」べき監視で、失敗が無言 `return 0` になっていれば block（P1 と重複）。
- 外部コマンド (`curl`, `wget`, `wine`) の失敗を想定し、タイムアウトや戻り値確認があるか。無人実行で**無限に待つ**可能性がある呼び出しは block。

## P5. 秘匿情報（block）

- LINE トークン/ID、アクセストークン、署名付き URL、パスワード、鍵を**ソースにハードコードしない**。設定は `~/.atst/`（リポジトリ外）から読む。
- 秘匿値を**ログ・標準出力・通知本文・コマンドライン引数**に出さない（`ps` で見える引数渡しに注意）。`set -x` を秘匿処理区間に残さない。
- 秘匿値を含みうるファイルを**コミット対象に追加**するコード・手順は block。`.gitignore` 整合も確認。

## P6. JSON / 外部入力のエスケープ（block〜warn）

- `curl -d '{...'"$var"'...}'` のように**変数を JSON へ文字列連結**する箇所は、`$var` に `"` / `\` / 改行 / 制御文字が入ると壊れる/インジェクションになる。ユーザー由来・MT 由来・ファイル由来の値を JSON に入れるなら**エスケープ必須**（`common.sh` の `atst_escape_text`、または `jq -Rn --arg`）。未エスケープは warn、外部入力なら block。
  - 現行の `atst_send_to_line` は jq があれば `jq --arg` で組み立て、無ければ `atst_escape_text` を通す（#20）。フォールバック経路はタブ等 `\n` 以外の制御文字を未エスケープなので、jq を導入しておくこと。

## P7. eval の安全性（block〜warn）

- `eval` は入力が**信頼できる文字列**（管理者が書いたもの等）に限る。外部・ネットワーク由来を `eval` するのは block。
  - ファイルシステム由来の値（フォルダ名など）は `eval` しない。`common.sh` の MT 一覧は `atst_load_mt_list` が配列へ直接代入する（#93）。

## P8. apt / 鍵 / リポジトリ（block）

- **`apt-key` は使用禁止**（新しめのディストロで廃止）。署名鍵は `/etc/apt/keyrings/` に dearmor して置き、`deb [signed-by=...] ...` で参照する。
- リポジトリ追加は `sources.list.d/*.list`(or `.sources`) に冪等に書く（`cat /etc/apt/sources.list | grep` 前提の判定は不可）。
- 外部リポジトリの追加は「distro 本体に無いときだけ」に限定する（例: FAudio は `apt-cache policy libfaudio0` で distro 提供を確認し、無い場合のみ opensuse を足す）。
- `apt-get install` に渡すパッケージ名は全対応ディストロに存在するものだけ。存在確認は `apt-cache policy <pkg>`（`LC_ALL=C` で `Candidate:` を見る）で行い、推測で決めない。
- **時刻同期は既存の time-daemon を維持する**: `systemd-timesyncd` / `ntp` / `ntpsec` / `chrony` のいずれかが既に動いていれば導入しない。無い場合のみ導入する（chrony は ntp/ntpsec と `time-daemon` で競合する）。
- スクリプトでは `apt` ではなく `apt-get` を使う（`apt` は CLI の互換性が保証されない）。

## P9. クロスディストロ / 可搬性（warn〜block）

- ディストロ判定は `/etc/os-release`（`ID` / `VERSION_ID` / `VERSION_CODENAME`）を使う。ハードコードのバージョン分岐は避ける。サポート外（EOL・未知・空）は**エラーを出して中断**する（§27）。
- GNU/BSD 差（`sed -r` vs `-E`、`date`）に触れるコードは分岐の正しさを確認（`common.sh` の `atst_escape_text` が `$OSTYPE` で分岐している前例あり）。
- bash 固有構文（`${var,,}`, 配列, `[[ ]]`, `let`）を使うなら shebang が `#!/bin/bash` であること（`#!/bin/sh` で bash 構文は block）。

## P10. Wine / MT 環境（block〜warn）

- Wine を使うコードは `WINEARCH` / `WINEPREFIX` / `DISPLAY` を**明示**して実行する（cron の最小環境では未定義になりうる）。
- **無人実行で GUI プロンプト・ダウンロードダイアログを誘発しない**: `wineboot` 等は `WINEDLLOVERRIDES="mscoree=;mshtml="` 等で mono/gecko の自動取得を抑止する。MT4/5 は .NET も埋め込み IE も不要。ブロッキングを招く変更は block。
- MT の検出・特定は `common.sh` の `atst_find_mt_index`（フォルダ名の前方一致・大文字小文字無視）に合わせる。独自の照合ロジックを増やさない。
- MT プロセスの特定は `common.sh` の `atst_find_pid`（`/proc` 走査）に合わせる。`ps | grep` や `winepath` で独自に探さない。

## P11. cron から動くスクリプトの堅牢性（warn）

- cron から動く前提のスクリプトは `PATH`・`cwd`・環境変数に依存しない（`common.sh` を絶対パス解決で source する既存パターン `. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"` を踏襲）。
- 毎分の監視は `check_all.sh` が固定の順で 1 つずつ実行する（同時多発の負荷を避ける設計）。毎分の監視を足すときは crontab に行を足さず `check_all.sh` の固定リストに足し、`run_check` の `timeout` の対象にして、打ち切りの通知（`RUNNER_TIMEOUT_*`）も付ける。毎分の監視の通知は `atst_update_alert`（状態あり）か `atst_notify_text`（文面だけ）で出す。`atst_send_to_line` を直接呼ぶと、その回のまとめ送信に入らず即時の個別 push になる（`check_order` の約定通知は即時でよい例外）。
- デバッグ用の固定パスへの出力・残骸（例: `>> $HOME/hoge` のような一時リダイレクト）を**残さない**。発見したら指摘。

## P12. 命名・構成の一貫性（warn）

- 公開関数・共通変数は `atst_*` / `ATST_*`。新規共通処理は `common.sh`（または内容の合う `lib/*.sh`）に置く。
  - 例外: `mt_home` / `mt_data` / `mt_name` / `mt_type` / `mt_term` は `atst_load_mt_list` が設定するグローバル配列で、`ATST_*` 命名の意図的な例外（これら以外の新規共通変数は `ATST_*` にする）。
- 1 スクリプト 1 責務。cron から叩く監視は `check_*.sh`、セットアップは `setup_*.sh` の命名に合わせる。
- テンプレート化すべき設定ファイルは `templates/` に置き、`%%PLACEHOLDER%%` 置換の既存流儀に合わせる。
- usage を持つスクリプトは引数不足時に usage を出して非 0 終了する（`run_with_targets.sh` の `print_usage_exit` 参照）。

## P13. install の fail-fast と最終検証（block）

- install / setup の**致命ステップ**（パッケージ導入、WineHQ リポジトリ設定、`wineboot`、MT インストーラの取得）は戻り値を確認し、失敗したら以降に進まず `[error]` を stderr に出して**非 0 で終了**する。失敗を無視して後続を続けるコードは block。
- 終了時は成果物を**検証してから**成功を表示する（例: `command -v wine`、`wine --version`、`[ -f "$WINEPREFIX/system.reg" ]`、インストーラファイルの存在）。**検証無しの無条件な成功表示は block**（実例: wine 不在のまま「installer is running」と表示した）。
- `/var/run/reboot-required` があれば、終了時に再起動を推奨する表示を出す（自動再起動はしない。P1）。
- 破壊的な既定動作を持つ対話（例: 既存 `WINEPREFIX` の削除）は**既定を安全側（N）**にし、無人実行（stdin が tty でない）では破壊しない。

## P14. リモート到達性の保全（block）

- パッケージの全体更新、または `systemd` / `openssh-server` を更新しうる処理の**直後（失敗時も）**に sshd を復帰させ、確認する:
  ```bash
  sudo install -d -m 0755 /run/sshd
  sudo systemctl start ssh.socket ssh 2>/dev/null || sudo systemctl start ssh
  ss -tlnp | grep -q ':22 ' || echo "[error] sshd is not listening" >&2
  ```
  OpenVZ では `/run/sshd` が再作成されず sshd が戻らないことがある。root crontab の `@reboot` 対策は再起動時にしか効かない（実例: svr1 で遠隔締め出し）。
- 現在の ssh 経路を断ちうる変更（sshd 設定・ファイアウォール・ネットワーク設定）は P1 の承認対象。

## P15. multi-arch・同版パッケージの整合と apt トランザクションの分離（block〜warn）

- 同一版を要求するパッケージ群（例: `winehq-stable` / `wine-stable` / `wine-stable-amd64` / `wine-stable-i386:i386`）は**一括で導入・更新する**。全体 `apt-get upgrade` に任せると片方だけ上がり、ファイル衝突で dpkg が壊れる（実例: wine 10→11 で `/opt/wine-stable/bin/wine` 衝突）。全体更新の前に `apt-mark hold` で除外し、後で一括更新する。dpkg 破損を起こしうる構成は block。
- 競合（`Conflicts` / 同一 `Provides`）しうるパッケージを**同じ `apt-get install` 行に混ぜない**。1 つが解決不能だと行全体が失敗し、他も巻き添えで入らない（実例: chrony×ntp）。必須群と任意群はトランザクションを分ける。

---

# 第III部: 具体パターン (How)

## 21. 共通ライブラリの source（→ P11）

```bash
#!/bin/bash
. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"
```

cwd に依存せず common.sh を読む。`$0` 版（`"$(cd "$(dirname "$0")" && pwd)"`）も既存にあるが、`$BASH_SOURCE` 版が source 耐性で堅い。新規は `$BASH_SOURCE` 版に揃える。

## 22. 冪等な追記・配置（→ P2）

```bash
# NG: 無条件追記（再実行で重複）
echo "$LINE" >> "$FILE"

# OK: 既存チェックしてから
grep -qF "$LINE" "$FILE" 2>/dev/null || echo "$LINE" >> "$FILE"

# OK: テンプレートから初回だけ配置
[ -e "$DST" ] || install -m 644 -D "$SRC" "$DST"
```

## 23. 外部コマンドの戻り値とタイムアウト（→ P4）

```bash
# HTTP ステータスで成否を判定（common.sh の curl は --max-time 付与済み: #22）
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url") || return 1
[ "$code" = "200" ] || return 1
```

ネットワーク呼び出しには `--max-time` を付け、無人実行でのハングを防ぐ。

## 24. JSON への安全な値埋め込み（→ P6）

```bash
# NG: 文字列連結（" や改行で壊れる）
data='{"text":"'"$msg"'"}'

# OK: jq で組み立て（エスケープを jq に任せる）
data=$(jq -Rn --arg t "$msg" '{text:$t}')
# jq が無い環境では atst_escape_text を通す（" \ 改行は対応済み: #20）。タブ等の制御文字は未対応なので jq を第一選択にする
```

## 25. 変数展開の防御（→ P3, P1）

```bash
# 破壊的操作は空ガードしてから
[ -n "$DIR" ] || { echo "DIR is empty" >&2; return 1; }
rm -rf "${DIR:?DIR must be set}"/*
```

`${VAR:?}` で「空なら即エラー」にすると、空変数による誤爆（`rm -rf /`）を構造的に防げる。

## 26. apt 鍵・リポジトリ（→ P8）

```bash
sudo install -d -m 0755 /etc/apt/keyrings
wget -q -O - "$KEY_URL" | sudo gpg --dearmor -o /etc/apt/keyrings/foo.gpg
echo "deb [signed-by=/etc/apt/keyrings/foo.gpg arch=amd64,i386] $REPO $CODENAME main" \
  | sudo tee /etc/apt/sources.list.d/foo.list > /dev/null
```

`apt-key` は使わない。`.list` の存在で冪等化する。

## 27. ディストロ判定（→ P9）

```bash
. /etc/os-release   # ID, VERSION_ID, VERSION_CODENAME
case "$VERSION_CODENAME" in
  focal|jammy|noble|bullseye|bookworm|trixie) : ;;   # サポート対象
  *) echo "[error] unsupported release: $VERSION_CODENAME" >&2; exit 1 ;;  # サポート外は中断
esac
```

---

# 付録: レビュアーペルソナ

レビューは以下の観点を順に当てる。各ペルソナは「見つけたら指摘する具体事象」を持つ。

## R1. 本番オペレーション / リスク担当（最優先）
- MT・建玉・cron・apt・reboot を触る自動処理に承認フローがあるか。異常の握りつぶし・監視の自己無効化が無いか。破壊的コマンドの空変数ガード。失敗の成功偽装、sshd 停止の放置。→ P1, P2, P11, P13, P14

## R2. シェルスクリプト品質担当
- クォート/word splitting、`$?` の扱い、パイプの失敗検知、`eval` の安全性、bash 構文と shebang の整合、関数長・重複。→ P3, P4, P7, P9, P12

## R3. セキュリティ担当
- 秘匿情報のハードコード/漏洩（ログ・引数・通知本文・コミット）、JSON/外部入力のエスケープ、`.gitignore` 整合。→ P5, P6

## R4. ディストリ/インフラ担当
- apt 鍵・リポジトリの正しさと冪等性、全対応ディストロでのパッケージ存在、Wine 環境変数と無人実行、OpenVZ 制約（swap/カーネル/sshd）、multi-arch の版整合と apt トランザクション分離。→ P8, P9, P10, P14, P15

## レビュー運用フロー

1. 変更ファイルごとに `bash -n` が通ることを確認（通らなければ即 block）。
2. `shellcheck -S warning *.sh` を当て、未抑止の警告を洗う（基準は 0 件。抑止する場合は対象の直前または同じ行に `# shellcheck disable=SCxxxx  # 理由`。理由なしの抑止は不可）。
3. R1→R4 の順でチェックリスト（P1〜P15）を当て、該当行を示して指摘する。重大度 block / warn を付ける。
4. block が 1 件でもあれば approve しない。warn は対応 or 明示的な見送り理由を求める。

## 最終チェックリスト（PR 前に自己点検）

- [ ] `bash -n` が全変更スクリプトで通る／`shellcheck -S warning *.sh` が 0 件（抑止は理由コメント付き）
- [ ] MT 停止・cron・apt・reboot 等、本番に影響する自動実行を増やしていない（増やすなら承認フロー付き）
- [ ] インストール/セットアップ処理は再実行しても壊れない（冪等）
- [ ] 変数・コマンド置換・配列展開をクォートした。破壊的操作に空変数ガードがある
- [ ] 外部コマンドの失敗を検知し、ネットワーク呼び出しに `--max-time` がある。無人実行でハング/プロンプトしない
- [ ] 秘匿情報をハードコード・ログ・引数・通知・コミットに出していない
- [ ] JSON へ入れる外部入力をエスケープした
- [ ] `apt-key` を使わず signed-by。追加リポジトリは distro に無いときだけ。パッケージは全対応ディストロに存在
- [ ] Wine を使うなら `WINEARCH`/`WINEPREFIX`/`DISPLAY` 明示、mono/gecko の自動取得を抑止
- [ ] `common.sh` の `atst_*` 流儀・命名・テンプレート配置に合わせた。デバッグ残骸（固定パス出力等）が無い
- [ ] install/setup は致命ステップの失敗で非 0 終了し、成果物を検証してから成功を表示する。破壊的な既定動作は安全側（P13）
- [ ] 全体更新・systemd/openssh 更新の後に sshd を復帰・確認している（P14）
- [ ] 同版要求の multi-arch 群は一括更新、競合しうるパッケージは別トランザクション、時刻同期は既存を維持（P15, P8）
- [ ] テストを足す／変える場合は `tests/` の sandbox 規約（実 `~/.atst`・`~/.wine`・LINE に触れない。詳細は CLAUDE.md「実行・検証」）に従い、`bats tests/` が通る
