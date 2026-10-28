# リリース手順（atst）

atst の配布は **git tag 単位**。新規導入・再導入で使われるのは Wiki が参照する gist の `init_atst.sh` で、その中身はリポジトリの `scripts/init_atst.sh`（master）と同一にする。`scripts/init_atst.sh` は固定の tag（`ATST_VERSION`）の GitHub archive zip を取得し、埋め込みの sha256（`ATST_ZIP_SHA256`）と一致したときだけ展開して `install_required_for_mt.sh` を実行する。**master へマージしただけでは配布されない**（`--channel master` を明示した利用者を除く）。

## 構造の注記

- tag `vX.Y.Z` に含まれる `scripts/init_atst.sh` は **1 つ前の版**を指す（自分自身の zip の sha256 は tag を打つ前には分からない）。新しい版を指す `scripts/init_atst.sh` は、tag を打った後の master に PR で入る。
- gist は常に **master の `scripts/init_atst.sh`** から更新する（tag の中のものを使わない）。
- sha256 は **push 後に GitHub から取得した archive** で計算する。手元で `git archive` で作った zip は、圧縮実装・タイムスタンプ・export 属性の違いで GitHub の archive とバイト列が一致しない。`scripts/release.sh` はこの順序（tag を push → GitHub から取得 → sha256）で行う。
- tag は `scripts/release.sh` でのみ打つ（3 要素 `vX.Y.Z`）。既存の 2 要素 tag（`v0.1`〜`v1.4`）は残し、版の比較には含める。
- GitHub Release（アセット）は作らない。GPG 署名付き tag も使わない。

## 前提

- master をチェックアウトしていて、追跡ファイルに未コミットの変更が無い。
- `origin` へ tag を push できる（terukusu として）。
- gh が terukusu で認証済み（gist の更新に使う）。

## 手順

1. リリースに含める変更をすべて master にマージする（install / setup / templates / cron 経路の変更はマージ前に実機検証を通す）。
2. `git switch master && git pull`
3. 計画を確認する（何も変更しない。`git ls-remote` / `git fetch` の読み取りだけ行う）:
   ```bash
   scripts/release.sh vX.Y.Z --dry-run
   ```
   作る tag・対象コミット・push 先・取得する URL・書き換えるファイル・直前の tag と、直前の tag からの `git log --oneline` を表示する。
4. 本実行:
   ```bash
   scripts/release.sh vX.Y.Z
   ```
   annotated tag を作り、`origin` へ **tag だけ** push し、`https://github.com/terukusu/auto-trading-support-tools/archive/refs/tags/vX.Y.Z.zip` を取得して sha256 を計算し、`scripts/init_atst.sh` の `ATST_VERSION` / `ATST_ZIP_SHA256` の 2 行だけを書き換える。リリースノートの雛形と残りの手順を stdout に出す。commit・ブランチの push・gist の更新はしない。
   - 前提検査（版の形式、作業ツリーがクリーン、同名 tag が無い、既存の最新 tag より新しい、`HEAD` が `origin/master`、書き換える 2 行がちょうど 1 行ずつある）に外れると `[error]` で止まり、何も変更しない。
   - push に失敗したらローカルの tag を消して止まる（そのまま再実行できる）。
   - push 後に zip を取得できなかったら tag は残したまま止まる。`scripts/release.sh --refresh-sha vX.Y.Z` で取得からやり直す。
5. 書き換えた `scripts/init_atst.sh` を PR で入れる:
   ```bash
   git switch -c release/vX.Y.Z
   git add scripts/init_atst.sh
   git commit -m "init_atst.sh: pin vX.Y.Z"
   git push -u origin release/vX.Y.Z
   gh pr create
   ```
   CI が通ったらマージする。
6. gist を master の `scripts/init_atst.sh` で更新する（gist ID は Wiki が参照している公開 gist のもの）:
   ```bash
   git switch master && git pull
   gh gist edit <gist-id> -f init_atst.sh scripts/init_atst.sh
   ```
7. gist とリポジトリが同一であることを確認する:
   ```bash
   gh gist view <gist-id> --raw -f init_atst.sh | diff - scripts/init_atst.sh
   ```
8. 初回（v1.5.0）と、配布経路を変えたリリースでは、**使い捨ての VPS** で Wiki の手順（gist の実行）を 1 回通し、tag の zip の取得・sha256 照合・展開・`install_required_for_mt.sh` の起動まで進むことを確認する。稼働中の本番 VPS では試さない。
9. リリースノートが必要なら、手順 4 の雛形を Issue / PR に貼る（GitHub Release は作らない）。

## 初回リリース（本方式の導入時）

- 本方式を入れた PR のマージ直後は、`scripts/init_atst.sh` がプレースホルダ（`ATST_VERSION=v0.0.0` / sha256 が全 0）のまま。既定の tag チャネルは取得前に `[error] no release is pinned yet ...` で止まる。
- gist は、初回リリースの sha 更新 PR がマージされるまで旧版（`master.zip` を取得するもの）のまま据え置く。差し替えの順序は **tag（`scripts/release.sh v1.5.0`）→ sha 更新 PR のマージ → gist の更新**。

## sha256 不一致の報告が来たとき（復旧）

GitHub は `archive/*.zip` のバイト列の安定を保証しておらず、過去に圧縮方式の変更で既存 archive のハッシュが一斉に変わった事例がある。照合不一致は「GitHub 側の再生成」か「改ざん」のどちらか。

1. tag が想定どおりのコミットを指しているか確かめる:
   ```bash
   git fetch origin --tags
   git ls-remote origin 'refs/tags/vX.Y.Z^{}'
   git rev-parse 'vX.Y.Z^{commit}'
   ```
   両者が一致し、そのコミットが想定したリリースであること。
2. GitHub の zip の中身と `git archive` の中身を比べる（バイト列ではなく展開後の内容）:
   ```bash
   d=$(mktemp -d)
   curl -fsSL --proto '=https' --max-time 120 -o "$d/gh.zip" \
     https://github.com/terukusu/auto-trading-support-tools/archive/refs/tags/vX.Y.Z.zip
   git archive --format=zip --prefix=auto-trading-support-tools-X.Y.Z/ -o "$d/local.zip" vX.Y.Z
   mkdir "$d/gh" "$d/local"
   unzip -q "$d/gh.zip" -d "$d/gh" && unzip -q "$d/local.zip" -d "$d/local"
   diff -r "$d/gh" "$d/local" && echo "same content"
   ```
3. 中身が同一（バイト列だけが変わった＝GitHub 側の再生成）なら、sha256 を取り直して PR → マージ → gist 更新:
   ```bash
   scripts/release.sh --refresh-sha vX.Y.Z --dry-run
   scripts/release.sh --refresh-sha vX.Y.Z
   ```
   `--refresh-sha` は既存の tag（origin にあるもの）の zip を取り直して 2 行を書き換えるだけで、tag の作成・push はしない。以後は手順 5〜7 と同じ。
4. 中身が違う、または tag が想定外のコミットを指しているなら**改ざんを疑う**。gist は更新せず調査する（tag の付け直しはしない）。

## 旧経路

- `scripts/init_atst.sh --channel master` は従来どおり `archive/master.zip` を取得する（sha256 照合なし。stderr に `[warn]` を出す）。明示したときだけ使われる。廃止時期は別途決める。
- Wiki の手順が gist の raw URL をリビジョン固定で参照している場合、gist を更新しても反映されない。gist 更新時に Wiki 側の参照も確認する（Wiki は別リポジトリ）。
