# NFS CSI lab — Zadara の NFS を CSI ドライバー経由で Pod にマウントする

Zadara (Ubuntu 24.04、`10.10.11.6`) の LV を NFS で公開し、k8s 側は
[csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs) で **PVC から動的に**ボリュームを作る。
`iscsi-pv-lab` (in-tree の `iscsi` プラグイン、手で作った静的 PV) との違いは、CSI ドライバーが
PVC ごとにサブディレクトリを作って PV を自動で用意すること。

```
RHEL k8s node 192.168.0.200                       Zadara 10.10.11.6 (VLAN 10)
┌───────────────────────────────┐                ┌─────────────────────────────────┐
│ Pod nfs-demo  /data           │                │ /srv/nfs/k8s  (XFS, LV          │
│   └ PVC nfs-demo (RWX, 1Gi)   │   NFS v4.1     │   ubuntu-vg/k8s-nfs, 20 GiB)    │
│      └ PV pvc-…  ─────────────┼── TCP 2049 ───→│   └ nfs-csi-lab-nfs-demo/       │
│ csi-nfs-node / -controller    │  (Cisco 経由)  │ nfs-kernel-server               │
│ (kube-system, hostNetwork)    │                │ export: 192.168.0.200 だけ      │
└───────────────────────────────┘                └─────────────────────────────────┘
```

| もの | 値 |
|---|---|
| NFS サーバー | Zadara `10.10.11.6:/srv/nfs/k8s` (LV `ubuntu-vg/k8s-nfs` 20 GiB、XFS、fstab で自動マウント) |
| export | `192.168.0.200(rw,sync,no_subtree_check,no_root_squash)` — RHEL ノードだけ |
| CSI ドライバー | csi-driver-nfs 4.13.6 (Helm リリース `csi-driver-nfs`、`kube-system`)、ドライバー名 `nfs.csi.k8s.io` |
| StorageClass | `nfs-zadara` (既定の StorageClass にはしていない)、`reclaimPolicy: Delete`、`nfsvers=4.1,hard` |
| サブディレクトリ | `<namespace>-<pvc 名>` (例: `nfs-csi-lab-nfs-demo`) |
| デモ | 名前空間 `nfs-csi-lab`、PVC `nfs-demo` (RWX 1Gi)、Pod `nfs-demo` (busybox、起動時に 1 行書くだけ) |

## 作り方

1. Zadara に LV と NFS サーバーを作る (何度実行しても同じ状態になる):
   ```bash
   ssh -i ~/.ssh/"id_rsa(opensssh)" tomi@10.10.11.6 'sudo bash -s' < nfs-csi-lab/zadara/setup-nfs.sh
   ```
   `apt-get install nfs-kernel-server` のあと needrestart が `devstack@c-vol` (cinder-volume) を
   再起動する。数秒止まるだけで、ほかの DevStack サービスには触らない。
2. CSI ドライバーを入れる:
   ```bash
   helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
   helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs --version 4.13.6 \
     -n kube-system -f nfs-csi-lab/k8s/csi-driver-nfs-values.yaml --wait
   ```
   変えているのは `controller.enableSnapshotter: false` だけ (VolumeSnapshot の CRD が無いため)。
   controller と node はチャートの既定で `hostNetwork` なので、firewalld が Pod → ホストを拒否する件
   (CLAUDE.md) には当たらない。ヘルスチェックは 29652 / 29653 / 19809 番 (ホスト上)。
3. StorageClass とデモを作る:
   ```bash
   kubectl apply -k nfs-csi-lab/k8s
   ```

## 確認

```bash
kubectl get csidriver nfs.csi.k8s.io                         # ATTACHREQUIRED false (attach の段階が無い)
kubectl get csinode -o custom-columns=NODE:.metadata.name,DRIVERS:.spec.drivers[*].name
kubectl -n kube-system get pods -l 'app in (csi-nfs-controller,csi-nfs-node)'
kubectl -n nfs-csi-lab get pvc,pod
MSYS_NO_PATHCONV=1 kubectl -n nfs-csi-lab exec nfs-demo -- sh -c 'mount | grep /data; cat /data/boot.log'
ssh tomi@10.10.11.6 'ls -la /srv/nfs/k8s/'                   # PVC ごとのサブディレクトリ
```

2026-11-17 の確認結果: PVC は作成から数秒で Bound、Pod の `/data` は
`10.10.11.6:/srv/nfs/k8s/nfs-csi-lab-nfs-demo type nfs4 (vers=4.1,rsize=1048576,wsize=1048576,hard,proto=tcp)`。
Pod で書いたファイルが Zadara のサブディレクトリにそのまま見える。

## 動きの流れ (どのコンポーネントが何をするか)

1. PVC 作成 → `csi-nfs-controller` の `csi-provisioner` サイドカーが `CreateVolume` を呼ぶ →
   controller の `nfs` コンテナが共有を一時マウントしてサブディレクトリを作り、PV を作る
2. Pod 作成 → NFS は attach が不要 (`attachRequired: false`) なので VolumeAttachment は作られない
3. kubelet → `csi-nfs-node` の `NodePublishVolume` → node プラグインがホストの
   `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/<pv>/mount` に NFS をマウント
   (マウント伝播 Bidirectional。`/var/lib/kubelet` が `shared` なので Pod から見える)
4. PVC 削除 → PV 削除 → controller がサブディレクトリを消す (`reclaimPolicy: Delete`)

## 注意

- **容量は守られない**: PVC の `1Gi` は記録上の値で、NFS には容量制限 (クォータ) が無い。
  Pod の `df` には共有全体 (20 GiB) が見え、書けばそのぶん使える。複数の PVC で 20 GiB を共有している
- **`no_root_squash`**: controller が root でサブディレクトリを作る/消すために必要。
  そのかわり export は RHEL ノード (`192.168.0.200`) だけに絞ってある
- **`hard` マウント**: Zadara が止まると、Pod の I/O は返ってこず待ち続ける (エラーにならない)。
  iSCSI と同じく、Zadara を止める前にこの Pod を消すこと
- **帯域は iSCSI と共有**: 経路は RHEL → 自宅ルーター/Cisco → Zadara の 1GbE 1 本で、iSCSI の負荷試験と
  同時に動かすと互いに遅くなる (64 MB の `dd conv=fsync` は iSCSI の負荷中に 50 MB/s だった)
- **ループで読み書きし続ける Pod を置かない**: ネットワーク代はかからないが、s3-pv-lab と同じ理由で
  (CLAUDE.md) デモ Pod は起動時に 1 行書くだけにしてある

## 片付け

```bash
kubectl delete -k nfs-csi-lab/k8s                 # Pod・PVC → PV とサブディレクトリも消える
helm uninstall csi-driver-nfs -n kube-system
# Zadara 側 (データごと消える):
ssh tomi@10.10.11.6 'sudo sed -i "\#/srv/nfs/k8s#d" /etc/exports /etc/fstab && sudo exportfs -ra \
  && sudo umount /srv/nfs/k8s && sudo lvremove -y ubuntu-vg/k8s-nfs'
```
