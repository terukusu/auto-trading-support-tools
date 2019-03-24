# Wine の設定を行う

## 概要

Windows アプリを Linux 上で動かすために [Wine](https://www.winehq.org/) というパッケージを設定する。


## 手順
SSHログインしたターミナルで以下を実行
```
$ wineboot
```

<img src="./images/remote5.png" width="480px">

* エラーメッセージが表示されるが、クラッシュしない限り問題ないので気にしなくてOK  


wine-mono と Gecko のインストールを求められるので、「インストール」を選んでインストールする。終わったらウィンドウが自動的に消えるが、それでOK  
<img src="./images/remote6.png" width="480px">


Wineの日本語フォントの設定  
SSH ログインしたターミナル上で以下を入力しエンターキー。

```
$ cat >>  ~/.wine/user.reg
```

続けて以下を入力してから 「Ctrl + d」

```
[Software\\Wine\\Fonts\\Replacements]
"MS Gothic"="VL Gothic"
"MS PGothic"="VL PGothic"
"MS Sans Serif"="VL PGothic"
"MS Shell Dlg"="VL Gothic"
"MS UI Gothic"="VL PGothic"
"Tahoma"="VL PGothic"
"\xff2d\xff33 \x30b4\x30b7\x30c3\x30af"="VL Gothic"
"\xff2d\xff33 \xff30\x30b4\x30b7\x30c3\x30af"="VL PGothic"
```

ターミナルは↓はこうなっているはず。  
<img src="./images/remote7.png" width="480px">


Wineの日本語表示を確認  
ターミナル上で以下を実行
```
$ winecfg
```
すると↓のWine設定画面が表示されるので、画面タブを開いて赤○の部分が文字化けしていないことを確かめる。  
<img src="./images/remote8.png" width="480px">  
確認できたら、「OK」をクリックして終了する。


ここまでで GUI の設定は完了。Windowsアプリを動かす準備ができました。
