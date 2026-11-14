# 02 ネットワークとルーター

VM をつなぐ自分専用のネットワークを作り、ルーターで外部ネットワーク `public` につなぐ。

```
 public (172.24.4.0/24, 外部)
    │  外部ゲートウェイ
 [lab-router]
    │  インターフェース 192.168.50.1
 lab-net / lab-subnet (192.168.50.0/24)
```

## 問題

1. ネットワーク `lab-net` を作る。
2. `lab-net` にサブネット `lab-subnet` を作る。範囲は `192.168.50.0/24`、ゲートウェイ `192.168.50.1`、
   DHCP 有効、DNS サーバー `8.8.8.8`。
3. ルーター `lab-router` を作り、外部ゲートウェイを `public` に設定する。
4. `lab-router` に `lab-subnet` をつなぐ。
5. `lab-router` のポートを一覧し、IP が 2 つ (外部側 172.24.4.x と内部側 192.168.50.1) あることを確かめる。
6. (考える) 手順 3 の外部ゲートウェイ設定を忘れると、後の問題 04 のどこで失敗するか。

## ヒント

- `openstack network create`、`openstack subnet create --network ... --subnet-range ...`
- `openstack router create`、`openstack router set --external-gateway ...`、`openstack router add subnet ...`
- `openstack port list --router lab-router`

答え合わせ: `bash scripts/check.sh 2`

<details>
<summary>解答例</summary>

```bash
openstack network create lab-net
openstack subnet create lab-subnet --network lab-net \
  --subnet-range 192.168.50.0/24 --gateway 192.168.50.1 --dhcp --dns-nameserver 8.8.8.8
openstack router create lab-router
openstack router set lab-router --external-gateway public
openstack router add subnet lab-router lab-subnet
openstack port list --router lab-router -c "Fixed IP Addresses"
```

6. VM の起動はできるが、**Floating IP の割り当て (問題 04 の手順 4) で失敗する**。エラーは
   `External network ... is not reachable from subnet ...`。Floating IP はルーターが NAT して届けるので、
   「サブネット → ルーター → 外部ネットワーク」の道がつながっていないと割り当てられない。
   問題 08 でこの失敗をわざと起こして確かめる。

</details>
