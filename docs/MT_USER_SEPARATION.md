# MetaTrader の実行ユーザーを分ける構成例（新規導入向け・未検証）

atst の標準の構成（Wiki の手順）は、sudo できるログインユーザー 1 人が VNC・Wine・MetaTrader・cron・`~/.atst` をすべて動かす「1 ユーザー構成」です。この文書は、新規に VPS を用意する人が任意で選べる「2 ユーザー構成」の例を説明します（#145）。

## ねらいと限界

- ねらい: MetaTrader（Wine）を sudo できない専用ユーザー（以下 `mt`）で動かし、悪意ある EA / DLL や改ざんされた MetaTrader・インストーラが、管理ユーザーの sudo 権限や `~/.ssh`（＝ VPS の制御権）に届かないようにします。
- 守れないもの: LINE トークン（`~/.atst/.line_token`）。通知を送る `send_to_line.sh` は `mt` の cron から動くので、トークンは `mt` のホームに置く必要があり、MetaTrader と同じユーザーから読めます。2 ユーザーにしても `line_token` は守れません。
- 守れないもの（その2）: 同じユーザーのファイル全般。Wine の `Z:` ドライブの撤去（`ATST_INSTALL_NO_ZDRIVE=1`。README の wine の項を参照）は、Windows 側のドライブとして `/` が見えなくなるだけです。Wine は `\\?\unix\` 形式のパスなど別の経路で Unix のファイルを開けるので、DLL を使う EA などが `~/.atst` や `~/.ssh` を読める余地は `Z:` 撤去後も残ります（使い捨て環境で `type \\?\unix\etc\hostname` が開けなかった観測はありますが、Win32 API から直接開けないことの確認ではありません）。なお winecfg でフォルダをホームにリンクすると、そのフォルダ経由で見えるようになります（導入直後の `drive_c/users` 配下にリンクが無いことは実機で確認済み）。
- したがって VPS の制御権（`~/.ssh`、sudo）を守る実効的な手段は、この文書の 2 ユーザー構成です。`Z:` 撤去は補助の緩和で、組み合わせても `line_token` や `mt` のファイルは守れません。
- 2 ユーザー構成も `Z:` 撤去も「緩和」で、完全な「隔離」ではありません。Wine はサンドボックスではありません。

## 前提と注意（未検証の構成例）

- 実機で通していない構成例です。手順どおりに動く保証はありません。うまくいかない場合は 1 ユーザー構成（Wiki の主線）に戻してください。
- `install_required_for_mt.sh` は 2 ユーザー構成を**サポートしません**（ユーザーの切り替えや、パッケージ導入と Wine 部分の分割はしません）。以下は、スクリプトを `mt` 本人として実行することで 2 ユーザーにする方法です。
- 新規の VPS 向けです。既存環境の移行は扱いません（最後の節）。
- パスワード無しの sudo（`NOPASSWD`）は設定しないでください。

## 手順

以下、`<admin>` は ssh でログインしている管理ユーザー（sudo できる）、`mt` は MetaTrader を動かすユーザーです。

1. 管理ユーザーで `mt` を作り、導入の間だけ sudo グループに入れます。install の中の `sudo`（apt、systemd、root の crontab など）を `mt` のパスワードで通すためです。
   ```
   sudo adduser mt              # 一時的なパスワードを付ける
   sudo usermod -aG sudo mt
   ```
2. `su - mt` で `mt` に入り、`mt` として導入します。`Z:` の撤去も合わせて指定するのを勧めます。
   ```
   su - mt
   ATST_INSTALL_NO_ZDRIVE=1 bash init_atst.sh
   ```
   - `sudo -iu mt` で入って実行しないでください。`SUDO_USER` が `<admin>` になり、install が VNC の systemd unit（`vncserver@:1.service`）の `User=` を `<admin>` にしてしまいます。
3. 確認します（`mt` のまま）。
   - 結果表示がすべて `[ OK ]`（`[ OK ] wine Z: drive: removed` を含む）。VNC のパスワードは結果表示に 1 回だけ出るので控えます。
   - `systemctl cat vncserver@:1` の `User=` が `mt`。
   - 続けて `mt` で `setup_line.sh`、`setup_cron.sh`（`mt` の crontab に入る）など、Wiki の以降の手順を進めます。
4. 管理ユーザーに戻り、`mt` の sudo とパスワードを外します。
   ```
   exit                         # mt から抜ける
   sudo deluser mt sudo
   sudo passwd -l mt
   ```
   以後 `mt` へは `<admin>` から `sudo -iu mt` で入ります（日常の操作は `SUDO_USER` の影響を受けません）。

接続について:

- ssh は従来どおり `<admin>` でログインし、VNC は `-L 5901:localhost:5901` のトンネル経由で接続します（VNC は localhost でしか待ち受けません）。
- VNC のパスワードは `mt` の `~/.vnc/passwd` です。`report_image.sh` の `vncsnapshot` も `mt` 側を使います。
- `<admin>` 側に `~/.wine` を作らないでください（どちらの prefix か分からなくなります）。
- 任意: `<admin>` のホームのパーミッションが 755（Ubuntu 20.04 の `adduser` 既定など）なら、`chmod 750` にすると `mt` から管理ユーザーのファイルが見えなくなります。

## 日常の運用（sudo の要否）

| 操作 | 実行するユーザー |
|---|---|
| パッケージ更新（apt、`purge_needless_packages.sh`）、`sudo reboot`、VNC unit の再起動、iptables | `<admin>` |
| install の再実行（unit 更新や sudo を伴う） | 手順 1・4 をもう一度行い、`mt` で実行 |
| `mtctl.sh`、`doctor.sh`、`check_*.sh`、`setup_cron.sh`、`setup_line.sh`、`report_image.sh` | `mt`（`sudo -iu mt` で入る） |

VNC unit の再起動は MetaTrader を止めてから行ってください（MetaTrader は VNC の画面上で動いています）。

## スコープ外（既存環境の移行）

- 既存環境は 1 ユーザー構成のままにしてください。移行の手順はここには書きません（別 Issue）。
- 既存環境で `Z:` だけを外す場合は README の wine の項を参照してください（MetaTrader を止めてから `rm ~/.wine/dosdevices/z:`。戻すときは `ln -s / ~/.wine/dosdevices/z:`）。
