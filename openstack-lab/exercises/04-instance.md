# 04 インスタンスの起動と Floating IP

問題 02 のネットワークと問題 03 のセキュリティグループ・キーペアを使って VM を起動し、外から SSH する。

## 問題

1. 次の条件で VM `lab-vm1` を起動し、`ACTIVE` になるまで待つ。
   イメージ cirros、フレーバー `m1.tiny`、ネットワーク `lab-net`、セキュリティグループ `lab-sg`、キーペア `lab-key`。
2. `lab-vm1` の内部 IP (192.168.50.x) と、乗っているホスト・状態を表示する。
3. コンソールログを表示し、cirros が起動して DHCP で IP をもらったことを確かめる。
4. 外部ネットワーク `public` から Floating IP を 1 つ取り、`lab-vm1` に割り当てる。
5. Zadara から Floating IP に ping し、`cirros` ユーザーで SSH して `ip a` と `hostname` を実行する。
6. (考える) VM の中で `ip a` を見ると、Floating IP (172.24.4.x) はどこにも無い。なぜ外から届くのか。

## ヒント

- `openstack server create ... --wait`、`openstack server show`、`openstack console log show`
- `openstack floating ip create public`、`openstack server add floating ip`
- `ssh -i ~/.ssh/lab-key cirros@<Floating IP>`
- 起動直後は SSH がまだ上がっていないことがある。数十秒待ってから試す

答え合わせ: `bash scripts/check.sh 4`

<details>
<summary>解答例</summary>

```bash
openstack server create lab-vm1 --image cirros-0.6.3-x86_64-disk --flavor m1.tiny \
  --network lab-net --security-group lab-sg --key-name lab-key --wait
openstack server show lab-vm1 -c status -c addresses -c OS-EXT-STS:power_state
openstack console log show lab-vm1 | grep -iE "lease|ip addr|login"

FIP=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip lab-vm1 "$FIP"
echo "$FIP"

ping -c 3 "$FIP"
ssh -i ~/.ssh/lab-key -o StrictHostKeyChecking=accept-new cirros@"$FIP" 'ip a; hostname'
```

`openstack server show` の `OS-EXT-SRV-ATTR:host` (乗っているホスト) は admin にしか見えない。labuser では表示されない。

6. Floating IP は **ルーター (`lab-router`) が持っている**。外から 172.24.4.x 宛てに来たパケットを、
   ルーターが宛先を VM の内部 IP 192.168.50.x に書き換えて (DNAT) 届ける。VM 自身は内部 IP しか知らない。
   この環境のルーターは OVN の論理ルーターなので、実体は `ovn-nbctl lr-nat-list` (admin) で見える。

</details>
