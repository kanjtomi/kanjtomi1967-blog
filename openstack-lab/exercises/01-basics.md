# 01 CLI とサービスの基本

最初に `cd ~/openstack-lab && source lab-openrc.sh` を実行しておく。

## 問題

1. 今の認証情報でトークンを発行し、トークンの有効期限 (`expires`) と、紐づいたプロジェクト ID を表示する。
2. サービスカタログを表示し、Compute (Nova)・Network (Neutron)・Image (Glance)・Block Storage (Cinder)
   それぞれの **public エンドポイント URL** を確認する。
3. 使えるイメージを一覧し、cirros イメージの **ディスク形式 (disk_format)** と **サイズ** を調べる。
4. フレーバーを一覧し、`m1.tiny` と `m1.small` の vCPU・メモリ・ディスクを比べる。
5. 自分のプロジェクト `lab` のクォータを表示し、インスタンス数・vCPU・メモリの上限を確認する。
6. (考える) `labuser` で `openstack user list` を実行するとどうなるか。理由も答える。

## ヒント

- `openstack token issue`、`openstack catalog list`、`openstack catalog show <サービス名>`
- `openstack image list` / `image show`、`openstack flavor list` / `flavor show`
- `openstack quota show` (プロジェクト名を省略すると自分のプロジェクト)
- `-f value -c 列名` で値だけ出せる。`-f json` や `-f yaml` も使える

<details>
<summary>解答例</summary>

```bash
# 1
openstack token issue -c expires -c project_id

# 2
openstack catalog list
openstack catalog show compute -f yaml        # endpoints の interface: public を見る
openstack endpoint list --interface public -c "Service Name" -c URL   # admin 権限が要るので labuser では 403 になる

# 3
openstack image list
openstack image show cirros-0.6.3-x86_64-disk -c disk_format -c size     # qcow2 / 約 21MB

# 4
openstack flavor show m1.tiny  -c vcpus -c ram -c disk
openstack flavor show m1.small -c vcpus -c ram -c disk

# 5  (行が Resource / Limit の表なので、grep で絞る)
openstack quota show | grep -E ' (instances|cores|ram) '
```

6. `HTTP 403 Forbidden` になる。ユーザー一覧は Keystone の管理操作で、`admin` ロールが必要。
   `labuser` は `lab` プロジェクトの `member` ロールしか持っていない (自分の情報は
   `openstack user show labuser` で見られる)。OpenStack の権限は「どのプロジェクトで、どのロールか」で決まる。

</details>
