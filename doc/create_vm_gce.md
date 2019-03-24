# VMインスタンス作成
## 概要

## 前提
* Google Cloud Platform (GCP) へのの登録(無料)は完了している
    * GCP プロジェクトが作成済みでそのプロジェクトで課金が有効になっている
        * 無料枠を利用するだけでも課金の設定が必要
* [gcloud コマンド](https://cloud.google.com/sdk/downloads?hl=JA)がインストール済み
* gcloud コマンドが認証済で、使用するGCPプロジェクトがデフォルトプロジェクトになっている

## VM 作成

ローカルマシンのターミナルで以下を実行
```
$ gcloud compute instances create tradevm --machine-type f1-micro --zone us-east1-b --image-project ubuntu-os-cloud --image-family ubuntu-minimal-1804-lts --boot-disk-type pd-standard --boot-disk-size 30
.....

NAME     ZONE        MACHINE_TYPE  PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP     STATUS
tradevm  us-east1-b  f1-micro                   xx.xxx.x.x   xxx.xxx.xxx.xxx  RUNNING
```  

ディスク容量が少なすぎてパフォーマンスが・・・のようなエラーメッセージが出るが気にせず進めてOK


VMインスタンスへSSHログイン

```
$ gcloud compute ssh <任意のユーザー名>@tradevm
```

* 任意のユーザー名のところは英数字で。今後も同じものを使うのであまり投げやりな名前にしないように  
* 初回の場合はここでSSHの暗号化鍵の生成が行われるが、よしなに肯定的に進めればOK
