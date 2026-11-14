# 03 セキュリティグループとキーペア

OpenStack の VM は、**セキュリティグループで許可した通信しか受け取らない**。
既定のグループ `default` は「同じグループの VM どうし」以外の受信を全部拒否するので、
外から ping も SSH も届かない。

## 問題

1. セキュリティグループ `lab-sg` を作る。
2. `lab-sg` に受信ルールを 2 つ足す: ICMP (ping) をどこからでも、TCP 22 (SSH) をどこからでも。
3. `lab-sg` のルールを一覧し、2 つのルールのほかに最初から入っている送信 (egress) ルールがあることを確かめる。
4. Zadara 上で SSH 鍵 `~/.ssh/lab-key` を作り、その公開鍵をキーペア `lab-key` として登録する。
5. (考える) 「TCP 22 をどこからでも」は実運用では勧められない。どう絞るのがよいか。

## ヒント

- `openstack security group create`、`openstack security group rule create --protocol ... --dst-port ... --ingress`
- `openstack security group rule list lab-sg`
- `ssh-keygen -t ed25519 -f ~/.ssh/lab-key -N ''`、`openstack keypair create --public-key ...`

答え合わせ: `bash scripts/check.sh 3`

<details>
<summary>解答例</summary>

```bash
openstack security group create lab-sg --description "ping and ssh for openstack-lab"
openstack security group rule create lab-sg --ingress --protocol icmp
openstack security group rule create lab-sg --ingress --protocol tcp --dst-port 22
openstack security group rule list lab-sg

ssh-keygen -t ed25519 -f ~/.ssh/lab-key -N '' -C openstack-lab
openstack keypair create --public-key ~/.ssh/lab-key.pub lab-key
```

3. IPv4 と IPv6 の egress (送信) ルールが 1 つずつ最初からある。VM から外への通信は既定で全部許可。
5. `--remote-ip` で送信元を絞る。例えば SSH は踏み台の IP だけ
   (`--remote-ip 172.24.4.1/32`)、あるいは `--remote-group` で「特定のグループに入っている VM からだけ」にする。

</details>
