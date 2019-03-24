# GUI の設定

## 概要
最小構成のLinuxにはGUIが含まれていないので、必要最小限のGUIを設定し、手元のPCからそのGUI画面に接続して操作できるようにする。

## 手順

### VMインスタンス側のGUI起動

ターミナルでVMインスタンスへSSHログイン

```
$ gcloud compute ssh --ssh-flag="-L5901:localhost:5901" <ユーザー名>@tradevm ← これはローカルマシンで実行
```


VMインスタンスへSSHログインしたターミナル上で以下を実行
```
$ vncserver -geometry 1280x800 -localhost -nolisten tcp

Password: ← リモートからGUIに接続する際のパスワードをここで決めて入れる。軟弱なものでOK(aaaとか)
Verify:
```


この段階でVMインスタンスのGUIに接続できるようになっています。↑のSSH接続がキープしている間は接続可能です。

### ローカルマシンからリモート接続ソフトでVMへ接続

Mac なら画面右上の「虫めがねアイコン」→「画面共有.app」と入力し画面共有を起動。  
<img src="./images/remote1.png" width="480px">  

* もしくは Mac の Fainder のメニューバーから 「移動」 → 「サーバーへ接続」 で、 `vnc://localhost:5901` と入力する
* もしくは [VNC Viewer](https://www.realvnc.com/en/connect/download/viewer/)をインストールしてそれを起動
    * VNCViewer は Mac 以外版もある


接続先に `localhost:5901` と入力して、「接続」をクリック  
<img src="./images/remote2.png" width="480px">


パスワードに vncserver に設定したパスワード入力して、「接続」をクリック  
<img src="./images/remote3.png" width="480px">


接続がうまくいけばこのようにVMインスタンスの画面が表示される。  
<img src="./images/remote4.png" width="480px">
