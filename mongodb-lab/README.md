# mongodb-lab — 学習用 MongoDB 7.0 (home RHEL k8s)

学習用の単一ノード MongoDB。本番経路 (S3 + CloudFront + Lambda) とは無関係。

- namespace: `mongodb-lab`、Deployment `mongodb`、image `docker.io/library/mongo:7.0.45` (バージョン固定)
- 認証あり: root ユーザー `admin`。パスワードはホストの `/root/mongodb-admin-password.txt`
  (root のみ読める 600) と Secret `mongodb-admin` (キー `username` / `password`) にだけある。**git に入れない。**
- データは `emptyDir`: コンテナ再起動では残るが、Pod を消すと消える。次の Pod は空の状態から
  Secret の値で root ユーザーを作り直す。データを残したくなったら `/glide` 配下に静的 hostPath PV を作る。
- 公開: Service `mongodb` は NodePort **30017** (`192.168.0.200:30017`)。firewalld の `lan`
  ゾーンで 30000-32767/tcp は開いているので、LAN からはファイアウォール変更なしで届く。
- CPU 0.5〜2、メモリ 1〜2Gi、WiredTiger キャッシュ 0.5GB (`--wiredTigerCacheSizeGB 0.5`)。
- MongoDB 5.0 以降は AVX 必須。ホストの CPU は AVX あり (確認済み)。
- readinessProbe は Pod IP への TCP。初回起動時の entrypoint は 127.0.0.1 だけで listen する
  認証なしの一時 mongod で root ユーザーを作るので、exec で localhost に ping する probe だと
  その一時 mongod で Ready になってしまう (実際にそうなった)。
- emptyDir は `/var/lib/kubelet` = `/glide` (USB SSD) 上にある。このディスクが遅いと初回起動に
  数分かかる (2026-11-07 は WiredTiger のオープンだけで 30 秒以上)。

## トラブル記録 (2026-11-07)

初回デプロイ時、イメージの pull がまったく進まなかった (`ctr images pull` でも 300 秒で 40KB)。
ホストのネットワークは正常。原因は `/glide` (sdb1) の I/O 停滞で containerd が詰まっていたこと:
dmesg に Nov 4 から `containerd-shim blocked for more than 122 seconds` が繰り返し出ていて、
他の Pod (strongswan / mariadb / dvwa) も `CreateContainerError: failed to reserve container name`
になっていた。`systemctl restart containerd` (ユーザー承認済み) で解消し、pull もすぐ終わった。

## デプロイ手順

```bash
# 1. namespace
kubectl apply -f mongodb-lab/k8s/namespace.yaml

# 2. パスワード生成と Secret 作成 (ホスト上で。パスワードを Windows 側に出さない)
ssh root@192.168.0.200 'bash -s' <<'EOF'
f=/root/mongodb-admin-password.txt
[ -s "$f" ] || (umask 077; tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 > "$f")
KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n mongodb-lab create secret generic mongodb-admin \
  --from-literal=username=admin --from-file=password="$f"
EOF

# 3. 本体
kubectl apply -k mongodb-lab
kubectl -n mongodb-lab rollout status deploy/mongodb
```

## 接続

```bash
# Pod 内の mongosh で (パスワードは Pod の環境変数から取る)
kubectl -n mongodb-lab exec -it deploy/mongodb -- sh -c 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'

# LAN の別マシン (mongosh インストール済み) から
mongosh "mongodb://admin@192.168.0.200:30017/?authSource=admin"   # パスワードはプロンプトで入力
```

## 片付け

```bash
kubectl delete namespace mongodb-lab
ssh root@192.168.0.200 rm -f /root/mongodb-admin-password.txt
```
