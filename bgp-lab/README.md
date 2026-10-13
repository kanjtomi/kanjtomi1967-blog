# BGP ラボ (Cisco C841M ⇔ FRR)

自宅の Cisco ルーターと、RHEL の k8s クラスタ上の FRR (Pod) で eBGP を張って練習する。

| | Cisco "Kobe" | FRR "frr-bgp" |
|---|---|---|
| 機器 | C841M (IOS 15.9) | k8s の Pod (namespace `bgp-lab`, FRR 10.4.1) |
| LAN アドレス | 192.168.0.100 (Gi0/4) | 192.168.0.210 (Pod の `net1`, Multus + macvlan) |
| AS | 65001 | 65002 |
| 広告するネットワーク | 10.10.10.0/24 (Vlan1), 172.16.1.0/24 (Loopback1) | 172.16.2.0/24 (lo) |
| 操作方法 | COM3 のコンソール (Tera Term) | `kubectl -n bgp-lab exec -it deploy/frr -- vtysh` |

FRR の Pod は、通常の Calico の `eth0` に加えて、Multus で LAN 直結の `net1` (macvlan, 固定 IP
192.168.0.210) を持つ。NAT を挟まないので eBGP の TTL や next-hop でつまずかず、RHEL の firewalld も
変更しない。FRR が覚えた経路は Pod の中だけに入り、RHEL 本体や他の Pod には影響しない。macvlan の
仕様で、RHEL 本体から 192.168.0.210 へは直接届かない。

## 構成ファイル

| ファイル | 内容 |
|---|---|
| `k8s/multus/` | Multus CNI (v4.3.1, thick)。Pod に 2 つ目のインターフェースを付けるため。クラスタに 1 回だけ入れる |
| `k8s/network.yaml` | `net1` の定義 (macvlan on `enp3s0`, 192.168.0.210/24) |
| `k8s/frr.yaml` | FRR の Deployment |
| `frr/frr.conf`, `frr/daemons` | FRR の設定。ConfigMap になって Pod に入る |

## 起動 / 停止 / CLI

この PC (Windows) の `kubectl` からそのまま操作できる。

```bash
kubectl apply -k bgp-lab/k8s/multus                  # 初回のみ: Multus
kubectl apply -k bgp-lab                             # FRR を起動 (frr/ を変えたらこれで反映)
kubectl -n bgp-lab exec -it deploy/frr -- vtysh      # FRR の CLI
kubectl -n bgp-lab rollout restart deploy/frr        # FRR を再起動 (設定は frr/frr.conf の状態に戻る)
kubectl -n bgp-lab scale deploy/frr --replicas=0     # 停止 (1 で再開)
```

vtysh で変えた設定は Pod の中だけにあり、Pod を作り直すと消える (練習中はこの方が便利)。
恒久的に変えるときは `frr/frr.conf` を編集して `kubectl apply -k bgp-lab`。

Cisco 側の設定 (Loopback1 と `router bgp 65001`) は startup-config に保存済み (2026-10-13)。ルーターを再起動しても残る。レッスンで変えた設定を残すときは `write memory`。

## 1. セッションを確認する

| 見たいこと | Cisco | FRR |
|---|---|---|
| ネイバーの状態 | `show ip bgp summary` | `show bgp summary` |
| BGP テーブル | `show ip bgp` | `show ip bgp` |
| 経路表に入った BGP 経路 | `show ip route bgp` | `show ip route bgp` |
| ネイバーの詳細 (タイマーなど) | `show ip bgp neighbors 192.168.0.210` | `show bgp neighbors 192.168.0.100` |

`State/PfxRcd` に数字が出ていれば Established (数字は受け取った経路数)。`Idle` / `Active` は未確立。

初回の結果: BGP プロセスを起動した直後、IOS は最適経路の計算と広告をしばらく待つ (update-delay)。
実測では、セッション確立から 61 秒後に Cisco の End-of-RIB が届いた。その間 `show ip bgp` の経路に
`>` が付かず、Cisco からの広告も出ない。セッションを張り直しただけのときは待ちは無い。

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

止め方によって、Cisco が経路を消すまでの時間が変わる。

**正常に止める** (FRR が NOTIFICATION を送るか、TCP が閉じられる → Cisco はすぐ気づく):

```bash
kubectl -n bgp-lab scale deploy/frr --replicas=0
```

**線が切れたように止める** (何も送らずに `net1` を落とす → Cisco は hold time まで待つ):

```bash
kubectl -n bgp-lab exec deploy/frr -- ip link set net1 down
```

Cisco が `%BGP-5-ADJCHANGE: neighbor 192.168.0.210 Down BGP Notification sent ... hold time expired`
を出すまで、既定では最大 180 秒。`net1` を上げる (`ip link set net1 up`) と再接続する。

タイマーを短くする (Cisco 側):

```
Kobe(config)# router bgp 65001
Kobe(config-router)# neighbor 192.168.0.210 timers 10 30
```

復旧 (どちらの場合も):

```bash
kubectl -n bgp-lab scale deploy/frr --replicas=1
kubectl -n bgp-lab rollout restart deploy/frr
```

## 6. 発展: FRR をもう 1 台

2 台目の FRR (例: 192.168.0.211, AS 65003) を同じ方法 (別の NetworkAttachmentDefinition と Deployment) で立て、両方から同じネットワークを広告すると、
AS-path prepend・MED・local-preference で Cisco の最適経路が切り替わる様子を観察できる。

## 片付け

```bash
kubectl delete -k bgp-lab
```

Multus も外すときは、DaemonSet を消したあとにホストの `00-multus.conf` も消す。残っていると、
新しい Pod が Multus を探して起動できなくなる:

```bash
kubectl delete -k bgp-lab/k8s/multus
ssh root@192.168.0.200 rm /etc/cni/net.d/00-multus.conf
```

Cisco 側 (startup-config に保存済みなので、消したあと `write memory` まで行う):

```
Kobe(config)# no router bgp 65001
Kobe(config)# no interface Loopback1
Kobe(config)# end
Kobe# write memory
```
