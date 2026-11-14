# 08 トラブルシューティング

わざと失敗させて、エラーの読み方と原因の探し方を覚える。ここで作ったものは最後に消す。

## 問題 A: クォータ超過

1. フレーバー `m1.xlarge` (8 vCPU、16GB) で VM `lab-big` を起動してみる。
2. どんなエラーになるか。原因をクォータの使用量から説明する。

## 問題 B: Floating IP が付けられない

1. ルーターにつながっていないネットワーク `lab-isolated` (サブネット `192.168.60.0/24`) を作る。
2. そこに VM `lab-iso` を起動し、Floating IP を割り当ててみる。
3. エラーメッセージを読み、問題 02 の構成と比べて原因を説明する。
4. 直し方を 1 つ挙げる (実際に直さなくてよい)。

## 問題 C: イメージの条件とフレーバーが合わない

イメージには「起動に最低これだけ要る」という条件 (`min_disk` / `min_ram`) を付けられる。

1. 問題 06 のスナップショットイメージ `lab-vm1-snap` の `min_disk` を 5 (GB) にする。
2. `lab-vm1-snap` から、フレーバー `m1.tiny` (ディスク 1GB) で VM `lab-tiny` を起動してみる。
   どんなエラーになるか。
3. 条件を満たすフレーバーを `openstack flavor list` から選んで `lab-tiny` を起動し直す。
   ただしクォータ (問題 A) を超えないものにする。
4. 終わったら `min_disk` を 1 に戻す (問題 06 の VM を作り直すときに困らないように)。
5. (考える) VM が作られたあとで `ERROR` 状態になったときは、どこを見れば原因がわかるか。

## 後片付け

```bash
openstack image set --min-disk 1 lab-vm1-snap
openstack server delete --wait lab-big lab-iso lab-tiny 2>/dev/null
openstack floating ip list --status DOWN -f value -c ID | xargs -r -n1 openstack floating ip delete
openstack subnet delete lab-isolated-subnet
openstack network delete lab-isolated
```

<details>
<summary>解答例</summary>

**A**

```bash
openstack server create lab-big --image cirros-0.6.3-x86_64-disk --flavor m1.xlarge --network lab-net
openstack quota show --usage | grep -E ' (cores|ram|instances) '
```

`403 ... Quota exceeded for cores, ram: Requested 8, 16384, but already used 2, 2560 of 8, 8192`
になり、**VM は作られずにすぐ断られる** (API の段階で止まるので、`openstack server list` にも出ない)。
`lab` のクォータは vCPU 8 / メモリ 8192MB。すでに `lab-vm1` と `lab-vm2` が vCPU 2・メモリ 2560MB を
使っていて、そこに 8 vCPU・16384MB を足すと両方とも上限を超える。

**B**

```bash
openstack network create lab-isolated
openstack subnet create lab-isolated-subnet --network lab-isolated --subnet-range 192.168.60.0/24
openstack server create lab-iso --image cirros-0.6.3-x86_64-disk --flavor m1.tiny \
  --network lab-isolated --security-group lab-sg --key-name lab-key --wait
FIP=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip lab-iso "$FIP"
```

VM は `ACTIVE` になるが、Floating IP の割り当てで
`External network ... is not reachable from subnet ...` になる。
`lab-isolated` はどのルーターにもつながっていないので、外部ネットワークまでの道が無い。
直し方は `openstack router add subnet lab-router lab-isolated-subnet`。

**C**

```bash
openstack image set --min-disk 5 lab-vm1-snap
openstack server create lab-tiny --image lab-vm1-snap --flavor m1.tiny --network lab-net
# → 400 Flavor's disk is smaller than the minimum size specified in image metadata.
#   Flavor disk is 1073741824 bytes, minimum size is 5368709120 bytes.

openstack flavor list                   # ディスク 5GB 以上でメモリの小さいもの → ds512M (512MB, 5GB)
openstack server create lab-tiny --image lab-vm1-snap --flavor ds512M --network lab-net --wait

openstack image set --min-disk 1 lab-vm1-snap
```

2. クォータ超過と同じく、**API の段階で断られて VM は作られない**。Nova は起動前に
   「フレーバーのディスク ≥ イメージの `min_disk`」を確かめている。スナップショットを取ると
   元のフレーバーのディスク (1GB) が `min_disk` に自動で入るので、小さすぎるフレーバーでの起動は普段から防がれている。
3. `m1.small` (20GB) でも条件は満たすが、メモリ 2048MB を足すとクォータ (8192MB) の残りを圧迫する。
   `ds512M` が一番小さい。

5. VM が作られてから `ERROR` になった場合 (ホストの資源不足、ネットワークのポート作成失敗など) に見る場所:
   - `openstack server show <VM> -c status -c fault` (まずここ。エラーの要約が入る)
   - `openstack server event list <VM>` → `openstack server event show <VM> <request-id>` で、どの処理で失敗したか
   - Nova のログ: `sudo journalctl -u devstack@n-cpu --since "10 min ago" | grep -i error`
     (スケジューラは `devstack@n-sch`、ネットワーク関連は `devstack@q-svc`)
   - 「No valid host」のときは、ホストにメモリやディスクの空きがあるかを admin で `openstack hypervisor show` で見る

</details>
