# BGP ラボ (Cisco C841M ⇔ FRR)

自宅の Cisco ルーターと、RHEL サーバー上の FRR コンテナで eBGP を張って練習する。

| | Cisco "Kobe" | FRR "frr-bgp" |
|---|---|---|
| 機器 | C841M (IOS 15.9) | RHEL 上の podman コンテナ (FRR 10.4.1) |
| LAN アドレス | 192.168.0.100 (Gi0/4) | 192.168.0.210 (macvlan) |
| AS | 65001 | 65002 |
| 広告するネットワーク | 10.10.10.0/24 (Vlan1), 172.16.1.0/24 (Loopback1) | 172.16.2.0/24 (lo) |
| 操作方法 | COM3 のコンソール (Tera Term) | `podman exec -it frr-bgp vtysh` |

FRR は macvlan で LAN 上に独立した IP を持つ。NAT を挟まないので eBGP の TTL や next-hop で
つまずかず、RHEL の firewalld も変更しない。FRR が覚えた経路はコンテナ内だけに入り、RHEL 本体や
Kubernetes には影響しない。macvlan の仕様で、RHEL 本体から 192.168.0.210 へは直接届かない。

## 起動 / 停止

```bash
bash /root/bgp-lab/run-frr.sh          # 起動 (作り直し)
podman stop frr-bgp                      # 停止
podman exec -it frr-bgp vtysh            # FRR の CLI
```

FRR の設定は `frr/frr.conf`。vtysh で変えた設定を残すなら vtysh で `write memory`
(コンテナに `frr/` をマウントしているのでホスト側のファイルが更新される)。

Cisco 側の設定は startup-config に保存していない。ルーターを再起動すると消える。残すなら `write memory`。

## 1. セッションを確認する

| 見たいこと | Cisco | FRR |
|---|---|---|
| ネイバーの状態 | `show ip bgp summary` | `show bgp summary` |
| BGP テーブル | `show ip bgp` | `show ip bgp` |
| 経路表に入った BGP 経路 | `show ip route bgp` | `show ip route bgp` |
| ネイバーの詳細 (タイマーなど) | `show ip bgp neighbors 192.168.0.210` | `show bgp neighbors 192.168.0.100` |

`State/PfxRcd` に数字が出ていれば Established (数字は受け取った経路数)。`Idle` / `Active` は未確立。

初回の結果: セッション確立後、IOS は最大 120 秒ほど最適経路の計算を待つ (update-delay)。その間
`show ip bgp` の経路に `>` が付かず、Cisco からの広告も出ない。待てば両側に経路が入る。

疎通確認 (BGP で覚えた経路で通信できるか):

```
Kobe# ping 172.16.2.1 source Loopback1
```

## 2. 経路を足す

FRR に広告するネットワークを足す:

```
frr-bgp# configure terminal
frr-bgp(config)# interface lo
frr-bgp(config-if)# ip address 172.16.20.1/24
frr-bgp(config-if)# exit
frr-bgp(config)# router bgp 65002
frr-bgp(config-router)# address-family ipv4 unicast
frr-bgp(config-router-af)# network 172.16.20.0/24
frr-bgp(config-router-af)# end
```

→ Cisco の `show ip bgp` に 172.16.20.0/24 が増える。

## 3. フィルタ (prefix-list / route-map)

FRR が Cisco から受け取る経路を 172.16.1.0/24 だけにする:

```
frr-bgp# configure terminal
frr-bgp(config)# ip prefix-list ONLY-LAB seq 10 permit 172.16.1.0/24
frr-bgp(config)# route-map FROM-CISCO permit 10
frr-bgp(config-route-map)# match ip address prefix-list ONLY-LAB
frr-bgp(config-route-map)# end
frr-bgp# clear bgp ipv4 unicast 192.168.0.100 soft in
frr-bgp# show ip bgp
```

→ 10.10.10.0/24 が消え、172.16.1.0/24 だけ残る。元に戻すには `route-map FROM-CISCO permit 10` の
`no match ip address prefix-list ONLY-LAB`。

FRR は RFC 8212 に従い、route-map の無い eBGP ネイバーとは経路を交換しない。`FROM-CISCO` /
`TO-CISCO` を最初から置いてあるのはそのため。route-map を消すと経路が全部止まるのも観察できる。

## 4. 経路の選択 (属性)

AS-path prepend: FRR から出す経路の AS パスを長く見せる:

```
frr-bgp(config)# route-map TO-CISCO permit 10
frr-bgp(config-route-map)# set as-path prepend 65002 65002
frr-bgp(config-route-map)# end
frr-bgp# clear bgp ipv4 unicast 192.168.0.100 soft out
```

→ Cisco の `show ip bgp` で 172.16.2.0/24 の Path が `65002 65002 65002 i` になる。経路が 1 本しか
ないので選択は変わらない。差が出るのは、同じネットワークへの経路が複数あるとき (6. で試す)。

local-preference (受け取った側で優先度を付ける, Cisco 側):

```
Kobe(config)# route-map FROM-FRR permit 10
Kobe(config-route-map)# set local-preference 200
Kobe(config-route-map)# exit
Kobe(config)# router bgp 65001
Kobe(config-router)# address-family ipv4
Kobe(config-router-af)# neighbor 192.168.0.210 route-map FROM-FRR in
Kobe(config-router-af)# end
Kobe# clear ip bgp 192.168.0.210 soft in
```

→ `show ip bgp` の LocPrf 列が 200 になる。

## 5. 障害試験

FRR を止めて、Cisco が経路を消すまでの時間を見る:

```bash
podman stop frr-bgp
```

Cisco のコンソールに `%BGP-5-ADJCHANGE: neighbor 192.168.0.210 Down` が出るまで、既定では最大
180 秒 (hold time)。プロセスが正常終了すると NOTIFICATION が送られて即座に落ちることもある。
違いを見るには `podman kill frr-bgp` (強制停止) と比べる。

タイマーを短くする (Cisco 側):

```
Kobe(config)# router bgp 65001
Kobe(config-router)# neighbor 192.168.0.210 timers 10 30
```

復旧:

```bash
bash /root/bgp-lab/run-frr.sh
```

## 6. 発展: FRR をもう 1 台

2 台目の FRR (例: 192.168.0.211, AS 65003) を同じ方法で立て、両方から同じネットワークを広告すると、
AS-path prepend・MED・local-preference で Cisco の最適経路が切り替わる様子を観察できる。

## 片付け

```bash
podman rm -f frr-bgp
podman network rm bgp-lan
```

Cisco 側 (startup-config には保存していないので、再起動でも消える):

```
Kobe(config)# no router bgp 65001
Kobe(config)# no interface Loopback1
```
