# IPsec VPN ラボ (Cisco C841M ⇔ strongSwan, IKEv1)

自宅の Cisco ルーターと、RHEL の k8s クラスタ上の strongSwan (Pod) の間で、ルートベースの
IPsec VPN を張って練習する。

| | Cisco "Kobe" | strongSwan |
|---|---|---|
| 機器 | C841M (IOS 15.9) | k8s の Pod (namespace `ipsec-lab`, Alpine 3.22 の strongswan パッケージ) |
| VPN の端点 (LAN) | 192.168.0.100 (Gi0/4) | 192.168.0.211 (Pod の `net1`, Multus + macvlan) |
| トンネル | `Tunnel10` 169.254.200.1/30 | `ipsec0` (XFRM, if_id 42) 169.254.200.2/30 |
| テスト用ネットワーク | `Loopback2` 172.16.11.0/24 | `lo` 172.16.12.0/24 |
| 操作 | COM3 のコンソール (Tera Term) | `kubectl -n ipsec-lab exec -it deploy/strongswan -- sh` |

| 項目 | 設定 |
|---|---|
| 鍵交換 | IKEv1 メインモード, PSK |
| フェーズ 1 (ISAKMP SA) | AES-256 / SHA-256 / DH group 14 (Cisco: `crypto isakmp policy 110`) |
| フェーズ 2 (IPsec SA) | ESP AES-256 / SHA-256, PFS group 14 (Cisco: transform-set `LAB-TS`, profile `LAB-IPSEC`) |
| 方式 | ルートベース (トラフィックセレクタは any⇔any、トンネルに入れる通信は経路で決める) |
| MTU | トンネル 1400 (ESP と外側の IP ヘッダーの分を空ける)。Cisco は `ip tcp adjust-mss 1360` |

## なぜ Alpine の strongSwan か

strongSwan 開発元のイメージ (`strongx509/strongswan`) は IKEv1 を外してビルドされていて、
IKEv1 のメインモード/クイックモードの処理が入っていない (Cisco は `MM_NO_STATE` のまま、strongSwan は
ログも出さずに失敗した)。Alpine の `strongswan` パッケージは IKEv1/IKEv2 両対応なので、Pod の起動時に
`apk add` で入れている (podman でイメージを作らないため)。起動には Pod の通常の `eth0` からインターネットに
出られる必要がある。

## 事前共有鍵 (PSK)

リポジトリには入れていない。RHEL 上の `/root/ipsec-lab-psk.txt` (root のみ読める) と、Secret
`ipsec-psk` (`kubectl -n ipsec-lab`) にだけある。Cisco 側は `crypto isakmp key <PSK> address 192.168.0.211`
としてユーザーが手で入力した。鍵を変えるときは、ファイルと Secret と Cisco の 3 か所をそろえる。

## 起動 / 停止

```bash
kubectl apply -k ipsec-lab                                   # 起動 (strongswan/ を変えたらこれで反映)
kubectl -n ipsec-lab rollout restart deploy/strongswan       # 再起動
kubectl -n ipsec-lab scale deploy/strongswan --replicas=0    # 停止 (1 で再開)
kubectl -n ipsec-lab logs -f deploy/strongswan               # IKE のログ
```

## 状態を確認する

| 見たいこと | Cisco | strongSwan |
|---|---|---|
| フェーズ 1 | `show crypto isakmp sa` (正常は `QM_IDLE`) | `swanctl --list-sas` の `ESTABLISHED` |
| フェーズ 2 と暗号化した数 | `show crypto ipsec sa interface Tunnel10` (`pkts encaps`/`decaps`) | `swanctl --list-sas` の `INSTALLED`, bytes/packets |
| まとめて | `show crypto session remote 192.168.0.211` | `swanctl --list-conns` |
| トンネルの状態 | `show interfaces Tunnel10` (`line protocol is up`) | `ip -s link show ipsec0` |
| 疎通 | `ping 172.16.12.1 source Loopback2` | `ping -I 172.16.12.1 172.16.11.1` |

初回の結果 (2026-10-14): 両側で確立、ping は両方向とも成功、Cisco の encaps/decaps が増えるのを確認。
両側とも自分から接続を始めるので、Cisco の `show crypto isakmp sa` に `QM_IDLE` が 2 本 (向きが逆) 出ることがある。

## 練習メニュー

1. **確立の流れを見る**: `kubectl -n ipsec-lab rollout restart deploy/strongswan` で張り直し、
   ログでメインモード 6 回 + クイックモード 3 回のやりとりを追う
2. **パケットを解析する**: UDP 500 (ISAKMP) と ESP (プロトコル 50) をキャプチャし、Wireshark で
   フェーズ 1/2 を確認する (中身は暗号化されて見えない)
3. **トンネルの MTU を測る**: `ping -M do -s <size>` で、トンネル越しに通る最大サイズを探す
   (Cisco には `crypto ipsec df-bit clear` があり、外側のパケットは分割されうる点にも注意)
4. **わざと失敗させる**: PSK の不一致、提案 (暗号方式) の不一致で、それぞれどんなエラーになるか
5. **トンネルの上で BGP**: 静的経路を BGP に置き換える

## 片付け

```bash
kubectl delete -k ipsec-lab
```

Cisco 側:

```
Kobe(config)# no ip route 172.16.12.0 255.255.255.0 Tunnel10
Kobe(config)# no interface Tunnel10
Kobe(config)# no interface Loopback2
Kobe(config)# no crypto ipsec profile LAB-IPSEC
Kobe(config)# no crypto ipsec transform-set LAB-TS
Kobe(config)# no crypto isakmp policy 110
Kobe(config)# no crypto isakmp key <PSK> address 192.168.0.211
```
