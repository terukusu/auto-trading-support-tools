# ADR 0001: Wine は 10 系に固定し、新規 prefix は win64 で作る

- 状態: 採用（2026-10-13）
- 関連: #40（調査 spike）、#66（wine 11 系への移行の追跡。調査ログの詳細あり）

## 背景

- MT4 の入手先は、ブローカー配布のインストーラ（`<broker>4setup.exe`）だけになっている。MetaQuotes 公式の `mt4setup.exe` を実行すると、MT5 が入る。
- これらのインストーラは **64bit（PE32+）** になった。インストールされる MT4 本体（`terminal.exe`）は 32bit（PE32）のままで、`Program Files (x86)` に入る。
- 従来、atst は `WINEARCH=win32` で prefix を作っていた。32bit の prefix では、64bit のインストーラを起動できない。
- WineHQ の stable は 11.0 になった。検証機（Ubuntu 24.04）での結果は次のとおり。
  - **wine 11 系では、MT4 のインストーラが起動しない。** 保護機構のデバッガ検出が誤って作動し、何も表示せずに終了するか、`A debugger has been found running in your system.` を表示して止まる。
    - 試した版: 11.0 stable、11.19 devel、11.19 staging
    - 試したインストーラ: Land Prime、Exness、OANDA、Pepperstone、XM Global
    - MT5 のインストーラでも同じ症状の報告がある。
  - **wine 11 系は、TightVNC 上で X エラー（SHAPE `X_ShapeMask` BadValue）になり落ちる。** prefix の初期化も MT4 本体も落ちる。
  - **wine 10.0 では、上記はどれも起きない。** 64bit の prefix で、インストーラ、MT4 の起動・ログイン、atst による検出・起動・停止まで動作を確認した。

## 決定

1. WineHQ stable を **10.0 に固定**する（`install_required_for_mt.sh` の `WINE_PIN_VERSION`）。
   - apt preferences（`/etc/apt/preferences.d/winehq-stable-pin`）に、Pin-Priority 1001 で書く。
   - 手動の `apt upgrade` や unattended-upgrades でも 11 に上がらない。すでに新しい版が入っている場合は、10 に戻す。
   - インストール後、版が固定どおりでなければエラーで止まる。
2. **新規の prefix は `WINEARCH=win64`** で作る。
   - 既存の prefix は、自分の arch（`system.reg` の `#arch`）のまま使い続ける。
   - `~/.bash_profile` の `WINEARCH` は、prefix の arch に合わせて書き換える。
   - 32bit の prefix を残した場合は、64bit のインストーラが動かない旨を警告する。
3. VNC は **TightVNC のまま**とする。wine 10 では問題がない。

## 結果

- 新規のインストールでは、64bit のインストーラが動き、32bit の MT4 が WoW64 で動く。
- 既存の win32 環境は、そのまま動き続ける（prefix は削除しない）。
- wine は自動では更新されない。wine 10 系の更新（セキュリティ修正を含む）は、10.0.x の範囲で受け取る。

## 見直しの条件

wine 側でインストーラのデバッガ誤検知が解消したら、wine 11 系以降へ移行する（#66）。移行時には、次の 2 つを同時に行う。

- 固定の解除（`WINE_PIN_VERSION` の更新）
- **TightVNC から TigerVNC などへの移行**（wine 11 系は TightVNC の SHAPE 1.0 で落ちるため）
