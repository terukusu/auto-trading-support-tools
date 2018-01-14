Ubuntu 16(64bit)でMT4を運用する環境を構築するための手順

# 概要
格安VPS + Ubuntu + VNC + Wine + MetaTrader4(or 5)で FX, CFDの自動売買環境を構築する。

# 環境
| 項目 | 使用ソフト・バージョン | 備考 |
|:-----------|:------------|:------------|
| VPS | [TIME4VPS](https://www.time4vps.eu) | 約260円(1.99€)/月 |
| OS | Ubuntu 16.04 |  |
| VNC | vnc4server | Ubuntu標準のもの |
| Wine | [WineHQ 3.0 rc4](https://www.winehq.org/) | RC版だけど手元では動作に問題無し |
| トーレドソフト | [MetaTrader4](https://www.metaquotes.net/) | 現在MT4のDLはできないので、どこかのFXブローカーからDLしてくる必要あり。MT5で良い人は公式からDLでOK |

# VPS準備
1. [TIME4VPSのサイト](https://www.time4vps.eu)でVPSを契約してVPSを１台用意する
    * 最低スペックのXSタイプでMT4が4つ程度動作可能
1. OS は Utbuntu 16.04 (64bit) をインストールする

# Tips(必要になったら使う)
apt-get install の undo  
```
$ awk '!/^Start|^Commandl|^End|^Upgrade:|^Error:/ { gsub( /\([^()]*\)/ ,"" );gsub(/ ,/," ");sub(/^Install:/,""); print}' /var/log/apt/history.log
$ sudo apt-get remove [packages]
```

xfceの設定初期化  
```
$ pkill xfconfd ; rm -rf ~/.config/xfce4/panel ~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
```

# もろもろ設定
**作業ユーザー作成していい感じにする**  
```
$ useradd teru -s /bin/bash -m
$ passwd teru
$ usermod -aG sudo teru
```

`~/.ssh/authorized_keys` に公開鍵入れておく

**ロケールを日本語に変更**  
```
$ sudo apt-get install language-pack-ja
$ sudo update-locale LANG=ja_JP.UTF-8
```

**タイムゾーンをJSTに**  
```
$ timedatectl set-timezone Asia/Tokyo
```  
↑ オプション無しで実行すると現在の設定が表示される

**パッケージのアップグレード**  
(※これやらないとmt4のインストールが途中で止まることが有る)
```
$ sudo apt-get install -f -y
$ sudo apt-get update -y
$ sudo apt-get upgrade -y
```

# デスクトップ環境  
ウィンドウマネージャ、Xサーバー、フォント等等必要な物をインストールする
```
$ sudo apt-get install -y xfce4 xfce4-goodies vnc4server fonts-vlgothic
```

※ キーボードレイアウトを聞かれるので「日本語 - かな86」を選択(正しいかは知らん)

※ VNCがクラッシュしたりする場合はTigerVNCを試す  
[http://tigervnc.bphinz.com/nightly/](http://tigervnc.bphinz.com/nightly/)  
↑のubuntu用のものを
[http://qiita.com/YuukiMiyoshi/items/7777bd36016d8ed1fae2](http://qiita.com/YuukiMiyoshi/items/7777bd36016d8ed1fae2)  
の手順で入れる

VNC Server を一度起動してパスワード設定と必要な設定ファイルを自動で作成する  
`$ vncserver`

VNC Serverは一旦終了  
`$ vncserver -kill :1`

~/.vnc/xstartup の 最後を startxfce4 & に書き換える

VNC Server起動  
`vncserver -geometry 1280x800 -depth 16`  
※ 色数は16bppくらいで十分でしょう

(vncserverのポートはディスプレイ:1ならば5901, :2 ならば 5902)

VNC Server に接続確認  
1. ポートフォワード有りで接続し直す  
`ssh -L5901:localhost:5901 <ユーザー名>@<ホスト名>`  
1. VNCクライアントでlocalhost:5901に接続する
 * Linuxデスクトップにアクセスできるはず  
 * VCNクライアントは Mac のFinderで「移動」→「サーバーへ接続」でも、[RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/)でも何でも良い

デスクトップメニューのアイコンが表示されないときは  
`設定→外観`  
で、テーマとアイコンを選択しなおせばOK

## Webブラウザのインストール
(chromeは何かと面倒なので避ける)
```
sudo apt-get install firefox
```
※ time4vpsは Lynxがわりとまともに動くのでそれでも良いかも

## 日本語入力
(イマイチ使えないのでやらないほうがマシ)  
ダメ：`sudo apt-get install fcitx-mozc`  
OK：`sudo apt-get install ibus-mozc`  

~/.vnc/xstartup に↓を追記
```
export GTK_IM_MODULE=ibus
export XMODIFIERS="@im=ibus"
export QT_IM_MODULE=ibus
/usr/bin/ibus-daemon -dxr
```

## Wineのインストール
(詳しくはWineHQのホムペで)

**Wineのリポジトリを追加**  
```
$ sudo apt-get install -y software-properties-common
$ sudo dpkg --add-architecture i386
$ wget -nc https://dl.winehq.org/wine-builds/Release.key
$ sudo apt-key add Release.key
$ sudo apt-add-repository 'deb https://dl.winehq.org/wine-builds/ubuntu/ xenial main'
```

**Wintricks をインストール**  
Wineの様々な設定に便利なツール
```
$ wget  https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks
$ chmod ugo+x winetricks
$ sudo mv winetricks /usr/local/bin/
```

**Wineをインストール**  
```
sudo apt-get install --install-recommends winehq-devel
```

**一旦wine起動**  
```
export DISPLAY=:1
export WINEARCH=win32
winecfg
(↑これはwineの設定ツール。ここでは自動で初期設定が行われるので見守るだけ。起動したら即終了でOK)
```

**日本語フォントを設定する**  
~/.wine/user.reg の末尾に↓これを追記する
```
[Software\\Wine\\Fonts\\Replacements] 1240428288
"MS Gothic"="VL Gothic"
"MS PGothic"="VL PGothic"
"MS Sans Serif"="VL PGothic"
"MS Shell Dlg"="VL Gothic"
"MS UI Gothic"="VL PGothic"
"Tahoma"="VL PGothic"
"\xff2d\xff33 \x30b4\x30b7\x30c3\x30af"="VL Gothic"
"\xff2d\xff33 \xff30\x30b4\x30b7\x30c3\x30af"="VL PGothic"
```

**モロモロのライブラリ導入**  
```
(不要かも？)$ winetricks dotnet40
(不要かも？)$ winetricks winhttp
(不要かも？)$ winetricks wininet
```
↑インストーラーが途中で止まるときに適宜突っ込んで見ると突破できることも有る
(2017/11/12 時点で、Ubuntu16.04にMT4を入れた時はインストールが途中で止まることもなく上記作業は不要だった)

# MetaTrader4をインストール
**インストーラをダウンロード**  
```
wget https://download.mql5.com/cdn/web/metaquotes.software.corp/mt4/mt4setup.exe
```
(↑何故かMT5がインストールされるので、どこかのFXブローカー(XM等)からMT4をDLしてくるのが良さそう)

**インストーラ起動**  
```
wine mt4setup.exe
```

セットアップ中のDLで止まる → インストールキャンセル → 再インストール を繰り返すとそのうち最後まで行ける

**MetaTrader4の起動**  
```
$ DISPALY=:1 WINARCH=win32 wine "/home/teru/.wine/drive_c/Program Files/MetaTrader 4/terminal.exe"
```

あとは普通に使うだけ。
メモリ不足になるのでfirefoxは終了しておくこと

## MT4を使うだけならここまででOK。以降はセキュリティ強化やより運用しやすいように行うための設定

# VNCとMT4の自動起動を設定
/etc/rc.local にvncとmt4の自動起動設定に以下の内容を追記
```
su -l teru -c "/usr/bin/vncserver :1 -geometry 1280x800 -depth 16"
su -l teru -c "DISPLAY=:1 WINEARCH=win32 WINEDEBUG=-all WINEPREFIX=/home/teru/.wine /usr/bin/wine /home/teru/.wine/drive_c/Program\ Files/MetaTrader\ 4/terminal.exe" &
```

↑teruの部分は適切なユーザー名で読み替え

# メモリ節約
xfce4はそれなりにメモリを使うので元祖なWMであるtwmを使う

```
sudo apt-get install twm
```

~/.vnc/xstartup の最後を↓こう変える
```
#startxfce4 &
twm &
```

twmの設定を追加
```
vi ~/.twmrc
```

↓これを書いておく
```
RandomPlacement
TitleFont "-misc"
Color
{
TitleBackground "skyblue"
}

RightTitleButton ":delete" = f.delete
Button1 = : root : f.menu "Menu"

menu "Menu"
{
"xterm" f.exec "xterm &"
"mt4" f.exec "/home/teru/bin/mt4.sh &"
"mt4_2nd" f.exec "/home/teru/bin/mt4_2nd.sh &"
}
```

mt4.sh はこんな感じ
```
teru@30194:~$ cat ~/bin/mt4.sh
#/bin/bash
DISPLAY=:1 WINEARCH=win32 WINEDEBUG=-all WINEPREFIX=/home/teru/.wine /usr/bin/wine start /d 'C:\Program Files\MetaTrader 4' /unix /home/teru/.wine/drive_c/Program\ Files/MetaTrader\ 4/terminal.exe
```

# screenにSSHエージェントを効かせる設定
~/.bash_profile に以下を記述
```
# Get the aliases and functions
if [ -f ~/.bashrc ]; then
        . ~/.bashrc
fi

agent="$HOME/.ssh-agent-$USER"
if [ -S "$SSH_AUTH_SOCK" ]; then
    case $SSH_AUTH_SOCK in
    /tmp/*/agent.[0-9]*)
        ln -snf "$SSH_AUTH_SOCK" $agent && export SSH_AUTH_SOCK=$agent
    esac
elif [ -S $agent ]; then
    export SSH_AUTH_SOCK=$agent
else
    echo "no ssh-agent"
fi

export WINEARCH=win32
```

# コマンドプロンプトに色を付ける
 ~/.bashrc 編集
`force_color_prompt=yes` をコメントアウト

↓ 追記(コマンドライン履歴をターミナル間で共有)
```
function share_history {
        history -a
        history -c
        history -r
}
PROMPT_COMMAND='share_history'
shopt -u histappend
export HISTSIZE=9999
```

# セキュリティ設定
**IPv4用の iptables の設定**  
```
$ sudo iptables -P INPUT DROP
$ sudo iptables -P FORWARD DROP
$ sudo iptables -P OUTPUT ACCEPT
$ sudo iptables -A INPUT -i lo -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,PSH,ACK,URG NONE -j DROP
$ sudo iptables -A INPUT -p tcp -m tcp ! --tcp-flags FIN,SYN,RST,ACK SYN -m state --state NEW -j DROP
$ sudo iptables -A INPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,PSH,ACK,URG FIN,SYN,RST,PSH,ACK,URG -j DROP
$ sudo iptables -A INPUT -p icmp -m icmp6 --icmp-type 128 -m hashlimit --hashlimit-upto 1/min --hashlimit-burst 10 --hashlimit-mode srcip --hashlimit-name t_icmp --hashlimit-htable-expire 120000 -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m state --state RELATED,ESTABLISHED -j ACCEPT
$ sudo iptables -A INPUT -p udp -m udp --sport 53 -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 22 --tcp-flags FIN,SYN,RST,ACK SYN -m hashlimit --hashlimit-upto 1/min --hashlimit-burst 10 --hashlimit-mode srcip --hashlimit-name t_sshd --hashlimit-htable-expire 120000 -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
```

**IPv6用の iptables の設定**  
```
$ sudo iptables -P INPUT DROP
$ sudo iptables -P FORWARD DROP
$ sudo iptables -P OUTPUT ACCEPT
$ sudo iptables -A INPUT -i lo -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,PSH,ACK,URG NONE -j DROP
$ sudo iptables -A INPUT -p tcp -m tcp ! --tcp-flags FIN,SYN,RST,ACK SYN -m state --state NEW -j DROP
$ sudo iptables -A INPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,PSH,ACK,URG FIN,SYN,RST,PSH,ACK,URG -j DROP
$ sudo iptables -A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 128 -m hashlimit --hashlimit-upto 1/min --hashlimit-burst 10 --hashlimit-mode srcip --hashlimit-name t_icmp --hashlimit-htable-expire 120000 -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m state --state RELATED,ESTABLISHED -j ACCEPT
$ sudo iptables -A INPUT -p udp -m udp --sport 53 -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 22 --tcp-flags FIN,SYN,RST,ACK SYN -m hashlimit --hashlimit-upto 1/min --hashlimit-burst 10 --hashlimit-mode srcip --hashlimit-name t_sshd --hashlimit-htable-expire 120000 -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
$ sudo iptables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
```

iptablesを永続化するためのパッケージ。インストールするタイミング注意。パッケージインストール時の iptables の設定が保存されるので iptables を設定してからインストールすること。
```
sudo apt install iptables-persistent
sudo dpkg-reconfigure iptables-persistent
```

# screenカスタマイズ
↓Ctrl+Tでエスケープ
```
# Escape key is C-t, literal is a.
escape ^Ta
```
