# SMB CSI lab — Zadara の Samba 共有を CSI ドライバー経由で Pod にマウントする

Zadara (Ubuntu 24.04、`10.10.11.6`) の LV を Samba で公開し、k8s 側は
[csi-driver-smb](https://github.com/kubernetes-csi/csi-driver-smb) で **PVC から動的に**ボリュームを作る。
構成は `nfs-csi-lab` とほぼ同じで、違いは **認証 (ユーザー名とパスワード) が要る**ことと、
**ノードで一度マウントしてから Pod にバインドする (NodeStage → NodePublish)** こと。

```
RHEL k8s node 192.168.0.200                       Zadara 10.10.11.6 (VLAN 10)
┌───────────────────────────────┐                ┌─────────────────────────────────┐
│ Pod smb-demo  /data           │                │ /srv/smb/k8s  (XFS, LV          │
│   └ PVC smb-demo (RWX, 1Gi)   │  SMB 3.1.1     │   ubuntu-vg/k8s-smb, 20 GiB)    │
│      └ PV pvc-…  ─────────────┼── TCP 445 ────→│   └ smb-csi-lab-smb-demo/       │
│ csi-smb-node / -controller    │  (Cisco 経由)  │ smbd、共有 [k8s]、ユーザー      │
│ (kube-system, hostNetwork)    │                │ k8s-smb、hosts allow 192.168.0.200│
│ Secret kube-system/           │                │ パスワード: /root/k8s-smb-      │
│   smb-zadara-creds            │                │   password.txt (root だけ)      │
└───────────────────────────────┘                └─────────────────────────────────┘
```

| もの | 値 |
|---|---|
| SMB サーバー | Zadara の Samba 4.19、共有 `//10.10.11.6/k8s` → `/srv/smb/k8s` (LV `ubuntu-vg/k8s-smb` 20 GiB、XFS、fstab で自動マウント) |
| アクセス制限 | `valid users = k8s-smb`、`hosts allow = 192.168.0.200` (RHEL ノードだけ)、`browseable = no`。nmbd (NetBIOS) は止めてある |
| 認証情報 | ユーザー `k8s-smb` (ログインできないシステムユーザー)。パスワードは Zadara の `/root/k8s-smb-password.txt` と Secret `kube-system/smb-zadara-creds` にだけある。**repo には入れない** |
| CSI ドライバー | csi-driver-smb 1.20.4 (Helm リリース `csi-driver-smb`、`kube-system`)、ドライバー名 `smb.csi.k8s.io` |
| StorageClass | `smb-zadara` (既定にはしていない)、`reclaimPolicy: Delete`、`vers=3.1.1,dir_mode=0777,file_mode=0666,mfsymlinks,noserverino` |
| サブディレクトリ | `<namespace>-<pvc 名>` (例: `smb-csi-lab-smb-demo`) |
| デモ | 名前空間 `smb-csi-lab`、PVC `smb-demo` (RWX 1Gi)、Pod `smb-demo` (busybox、起動時に 1 行書くだけ) |

## 作り方

1. Zadara に LV、Samba、ユーザー、共有を作る (何度実行しても同じ状態。パスワードは初回だけ生成):
   ```bash
   ssh -i ~/.ssh/"id_rsa(opensssh)" tomi@10.10.11.6 'sudo bash -s' < smb-csi-lab/zadara/setup-smb.sh
   ```
   `apt-get install samba` のあと needrestart が `devstack@c-vol` (cinder-volume) を再起動する (数秒)。
2. CSI ドライバーを入れる:
   ```bash
   helm repo add csi-driver-smb https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts
   helm upgrade --install csi-driver-smb csi-driver-smb/csi-driver-smb --version 1.20.4 \
     -n kube-system -f smb-csi-lab/k8s/csi-driver-smb-values.yaml --wait
   ```
   変えているのは Windows 用 DaemonSet を止めることとログレベル (5 → 2) だけ。controller と node は
   チャートの既定で `hostNetwork` (ヘルスチェック 29642 / 29643、メトリクス 29644)。
3. 認証情報の Secret を作る (パスワードは画面にもファイルにも残さず、Zadara から直接流し込む):
   ```bash
   T=$(mktemp); ssh tomi@10.10.11.6 'sudo cat /root/k8s-smb-password.txt' | tr -d '\r\n' > "$T"
   kubectl -n kube-system create secret generic smb-zadara-creds \
     --from-literal=username=k8s-smb --from-file=password="$T"; rm -f "$T"
   ```
   Secret を `kube-system` に置くのは、デモの名前空間を消しても PV の削除 (サブディレクトリの削除に
   認証が要る) が失敗しないようにするため。
4. StorageClass とデモを作る:
   ```bash
   kubectl apply -k smb-csi-lab/k8s
   ```

## 確認

```bash
kubectl get csidriver smb.csi.k8s.io                         # ATTACHREQUIRED false
kubectl -n kube-system get pods -l 'app in (csi-smb-controller,csi-smb-node)'
kubectl -n smb-csi-lab get pvc,pod
MSYS_NO_PATHCONV=1 kubectl -n smb-csi-lab exec smb-demo -- sh -c 'mount | grep /data; cat /data/boot.log'
ssh tomi@10.10.11.6 'sudo ls -la /srv/smb/k8s/; sudo smbstatus -b'   # サブディレクトリと接続中のクライアント
```

2026-11-17 の確認結果: PVC は数秒で Bound。Pod の `/data` は
`//10.10.11.6/k8s/smb-csi-lab-smb-demo type cifs (vers=3.1.1,soft,rsize=4194304,wsize=4194304,…)`。
Zadara の `smbstatus` では `k8s-smb` が `192.168.0.200` から `SMB3_11`、署名あり・暗号化なしで接続。
Pod で書いたファイルは Zadara 上で `k8s-smb` の所有になる (`force user`)。
64 MB の `dd conv=fsync` は 52 MB/s (iSCSI の負荷試験と回線を共有していたとき)。

## NFS (nfs-csi-lab) との違い

| | NFS (`nfs.csi.k8s.io`) | SMB (`smb.csi.k8s.io`) |
|---|---|---|
| 認証 | なし (IP で export を絞るだけ) | ユーザー名 + パスワード (Secret) |
| ノードでのマウント | Pod ごとに直接マウント (NodePublish) | ノードで 1 回 `globalmount` にマウントし (NodeStage)、Pod へバインド |
| ファイルの所有者 | クライアントの UID のまま (`no_root_squash`) | サーバー側は全部 `k8s-smb`。Pod 側の見え方は `uid`/`gid`/`file_mode`/`dir_mode` のマウントオプションで決まる |
| 既定のマウント | `hard` (サーバーが止まると待ち続ける) | `soft` (タイムアウトでエラーが返る) |
| シンボリックリンク | そのまま | `mfsymlinks` で特殊ファイルとして保存 |

ホストの `findmnt -t cifs` では、`plugins/kubernetes.io/csi/smb.csi.k8s.io/<hash>/globalmount` と
`pods/<uid>/volumes/kubernetes.io~csi/<pv>/mount` の 2 つが見える (`/glide` のバインドマウントでそれぞれ 3 か所)。

## 注意

- **容量は守られない**: PVC の `1Gi` は記録上の値。Samba 側にクォータは無く、20 GiB を全 PVC で共有する
- **通信は暗号化されていない**: 署名 (AES-128-CMAC) はあるが、中身は平文で LAN を流れる。必要なら
  StorageClass の `mountOptions` に `seal` を足す (SMB3 暗号化。Samba 側は既定で受け入れる)
- **パスワードを変えるとき**: Zadara の `/root/k8s-smb-password.txt` を消して `setup-smb.sh` を再実行 →
  手順 3 の Secret を作り直す → 既存のマウントは Pod を作り直すまで古い認証のまま
- **帯域は iSCSI / NFS と共有**: どれも RHEL → Cisco → Zadara の 1GbE 1 本を通る
- **ループで読み書きし続ける Pod を置かない** (CLAUDE.md の s3-pv-lab の教訓)

## 片付け

```bash
kubectl delete -k smb-csi-lab/k8s                 # Pod・PVC → PV とサブディレクトリも消える
kubectl -n kube-system delete secret smb-zadara-creds
helm uninstall csi-driver-smb -n kube-system
# Zadara 側 (データごと消える):
ssh tomi@10.10.11.6 'sudo sed -i "\#include = /etc/samba/k8s-share.conf#d" /etc/samba/smb.conf \
  && sudo rm -f /etc/samba/k8s-share.conf && sudo systemctl restart smbd \
  && sudo sed -i "\#/srv/smb/k8s#d" /etc/fstab && sudo umount /srv/smb/k8s && sudo lvremove -y ubuntu-vg/k8s-smb \
  && sudo smbpasswd -x k8s-smb && sudo userdel k8s-smb && sudo rm -f /root/k8s-smb-password.txt'
```
