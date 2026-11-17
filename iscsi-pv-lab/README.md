# iscsi-pv-lab — Zadara の iSCSI LUN を k8s の PV にする

Zadara (Ubuntu 24.04、DevStack が動いているサーバー) の LIO iSCSI ターゲットから 10GB の LUN を出し、
自宅 RHEL の k8s で静的 PV としてマウントする練習環境。2026-11-14 に構築・動作確認済み。

```
 RHEL k8s node 192.168.0.200                         Zadara 10.10.11.6 (VLAN 10)
 ┌─────────────────────────────┐   iSCSI TCP 3260   ┌──────────────────────────────┐
 │ kubelet ─ iscsiadm (iscsid) │ ─ 自宅ルーター ─  │ LIO target                   │
 │   /dev/sdc (ext4)           │   ─ Cisco ─ VLAN10 │ iqn.2026-11.local.kanjhome.  │
 │   └ pod iscsi-pv-lab-demo   │                    │   zadara:k8s-pv1  LUN 0      │
 │       /data                 │                    │ └ LV ubuntu-vg/k8s-iscsi-pv1 │
 └─────────────────────────────┘                    └──────────────────────────────┘
```

| 項目 | 値 |
|---|---|
| ターゲット | `iqn.2026-11.local.kanjhome.zadara:k8s-pv1`、ポータル `10.10.11.6:3260` (VLAN 10 の固定 IP だけで待ち受け) |
| LUN | 0、block バックストア `/dev/ubuntu-vg/k8s-iscsi-pv1` (10GB の LV) |
| アクセス制御 | ACL で RHEL のイニシエーター `iqn.1994-05.com.redhat:f4128de7e8e` だけに LUN を見せる。CHAP なし (LAN 内のみ) |
| k8s | namespace `iscsi-pv-lab`、PV `iscsi-pv-lab-pv` (in-tree `iscsi`、ext4、RWO、Retain)、PVC `iscsi-pv-lab-pvc`、Pod `iscsi-pv-lab-demo` |

## 作り方

1. Zadara にターゲットを作る (何度実行しても同じ状態になる):
   ```bash
   ssh tomi@10.10.10.4 'sudo bash -s' < iscsi-pv-lab/zadara/setup-target.sh
   ```
2. RHEL で iscsid を有効にし、ターゲットが見えるか確かめる:
   ```bash
   systemctl enable --now iscsid.socket
   iscsiadm -m discovery -t sendtargets -p 10.10.11.6:3260
   ```
   ログイン (`iscsiadm -m node --login`) は手でしない。kubelet が Pod の起動時に行う。
3. k8s:
   ```bash
   kubectl apply -f iscsi-pv-lab/k8s/iscsi-pv-lab.yaml
   kubectl -n iscsi-pv-lab logs iscsi-pv-lab-demo    # boot.log と df -h /data
   ```
   初回は kubelet が LUN を ext4 でフォーマットする。Pod を消して作り直すと `boot.log` の行が増える
   (データが LUN 側に残っている)。

## 確認

```bash
# RHEL
iscsiadm -m session                       # 10.10.11.6:3260 ... k8s-pv1
lsblk -o NAME,SIZE,TRAN,MOUNTPOINTS       # sdc 10G iscsi /…/kubernetes.io~iscsi/iscsi-pv-lab-pv
# Zadara
sudo targetcli sessions                   # alias: redhat.kanjhome.local ... LOGGED_IN
```

## 注意

- **Cinder と同じ LIO を共有している**: DevStack の Cinder (`target_helper = lioadm`) も同じ LIO に
  OpenStack ボリューム用のターゲットを作る。`targetcli clearconfig` や `/iscsi` ごとの削除はしないこと。
  `saveconfig` は Cinder のターゲットも含めて `/etc/rtslib-fb-target/saveconfig.json` に保存し、
  起動時に `rtslib-fb-targetctl.service` が戻す。
- **RWO**: ext4 を載せたブロック LUN なので、同時にマウントできるのは 1 ノードだけ (このクラスタは 1 ノード)。
  2 ノードから同時に書くとファイルシステムが壊れる。
- **経路**: RHEL → 10.10.11.6 は自宅ルーター (192.168.0.1) の静的ルート経由で Cisco に届く。
  Cisco か Zadara が止まると、Pod の I/O は止まって待つ (iSCSI のタイムアウト後にエラー)。
- **Pod → ホストの firewalld は関係ない**: iSCSI のログインとマウントは kubelet がホスト側で行うので、
  Pod からホストへの通信が拒否される件 (CLAUDE.md 参照) には当たらない。

## 性能の練習

`bench/` の `iscsi-bench` Pod (イメージは `linux-tuning-lab` の `localhost/tuning-tools:local`) が
同じ PVC を `/data` にマウントする。1 ノードなので RWO でも demo Pod と同時に使える。

```bash
kubectl apply -k iscsi-pv-lab/bench
MSYS_NO_PATHCONV=1 kubectl -n iscsi-pv-lab exec iscsi-bench -- /bench/06-iscsi.sh 10 512M
```

経路 (`ip route get`、`tracepath` のパス MTU)、ping の RTT、fio 4 種類を iSCSI (`/data`) と
ローカル NVMe (`/scratch`) で出す。作業ファイルは `/data/fio-bench` にだけ作って消す。

結果 (11-15 は Cisco Gi0/4 が 100Mbps、11-17 はケーブル交換で 1Gbps になった後):

| テスト | iSCSI 2026-11-15 | iSCSI 2026-11-17 | ローカル NVMe |
|---|---|---|---|
| 順次読み込み 1M qd8 | 11.2 MB/s (p50 709 ms) | **111.5 MB/s** (p50 72 ms) | 3,193 MB/s |
| ランダム読み込み 4k qd1 | 782 IOPS (p50 1.2 ms) | 857 IOPS (p50 1.1 ms) | 10,750 IOPS (82 us) |
| ランダム読み込み 4k qd32 | 2,775 IOPS (p50 11.5 ms) | **22,244 IOPS** (p50 1.4 ms) | 130,540 IOPS |
| ランダム書き込み 4k + fsync | 104 IOPS | 115 IOPS | 162 IOPS |

ネットワーク: ping RTT 1.6 ms、パス MTU 1480 (Pod の Calico `eth0`)、4 ホップ
(Pod → ホスト → 自宅ルーター → Cisco 192.168.0.100 → Zadara)。

**解決済み (2026-11-17): 順次読み込みが 11 MB/s で頭打ちだった原因**は、Cisco C841M の
Gi0/4 (192.168.0.100、自宅 LAN 側) が auto 設定のまま **100Mbps でリンクアップ**していたこと
(`show interfaces gi0/4` → `Full Duplex, 100Mbps`、lost carrier 80 回)。RHEL ↔ Zadara の通信は
行きも帰りもこのポートを通るので、両方向とも ~94 Mbps に絞られていた。ケーブルを交換して
1Gbps になり、順次読み込みは 1GbE の線速 (~111 MB/s) まで出るようになった。

見つけ方の記録:

- RHEL で `ss -ti dst 10.10.11.6` — `delivery_rate 97.2Mbps` (100Mbps 回線に張り付き)、
  `minrtt 0.47 ms` に対し転送中の `rtt` が ~14 ms (ボトルネックでキューが溜まる)。TCP ウィンドウ
  (`rcv_ssthresh` ~700 KB) は 12 ms × 11 MB/s ≒ 135 KB より十分大きく、律速ではなかった
- Cisco コンソール (COM3) で `show interfaces status` (スイッチポート Gi0/0-3) と
  `show interfaces gi0/4` (WAN 側のルーテッドポート、`status` には出ない) を見る
- C841M (CPU は P1021SEC、公式の性能値は「サービス多数有効で 30 Mbps 超」だけ) の CPU は、
  1Gbps 線速の順次読み込み中でも 5 秒平均 29% (うち割り込み 23% = CEF の高速パス)。
  この経路では Cisco の CPU は律速にならない

ホスト側 (イニシエーター) で見るもの:

```bash
iscsiadm -m session -P 3               # セッションの状態、MaxRecvDataSegmentLength (262144)、タイムアウト
cat /sys/block/sdc/device/queue_depth  # 32 (LUN ごとのキュー深度)
cat /sys/block/sdc/queue/scheduler     # [mq-deadline]
iostat -x sdc 1                        # r_await / aqu-sz
multipath -ll                          # マルチパスは未設定 (パスは 1 本、ポータルも 1 つ)
```

ターゲット側 (Zadara) で見るもの: `sudo targetcli sessions`、`iostat -x dm-* 1` (LV の負荷)、
`/sys/kernel/config/target/iscsi/<iqn>/tpgt_1/param/` (ネゴシエーションの値)。

## 片付け

```bash
kubectl delete -k iscsi-pv-lab/bench                     # 性能練習用の Pod
kubectl delete -f iscsi-pv-lab/k8s/iscsi-pv-lab.yaml    # kubelet がログアウトする
# Zadara
sudo targetcli /iscsi delete iqn.2026-11.local.kanjhome.zadara:k8s-pv1
sudo targetcli /backstores/block delete k8s-iscsi-pv1
sudo targetcli saveconfig
sudo lvremove -y ubuntu-vg/k8s-iscsi-pv1                # LUN の中身も消える
```
