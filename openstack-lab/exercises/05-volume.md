# 05 ボリューム (Cinder)

VM のルートディスクは VM を消すと一緒に消える。消えずに残したいデータはボリュームに置く。

## 問題

1. 1GB のボリューム `lab-vol1` を作り、`available` になるまで待つ。
2. `lab-vol1` を `lab-vm1` に接続し、状態が `in-use` になったことと、接続先のデバイス名 (`/dev/vdb` など) を確かめる。
3. `lab-vm1` に SSH し、`cat /proc/partitions` で新しいディスクが見えていることを確かめる。
4. `lab-vm1` から `lab-vol1` を取り外す。
5. 取り外した `lab-vol1` のスナップショット `lab-vol1-snap` を作る。
6. (考える) 接続したままスナップショットを取ろうとするとどうなるか。

## ヒント

- `openstack volume create --size 1`、`openstack volume show -c status`
- `openstack server add volume`、`openstack server remove volume`
- `openstack volume snapshot create --volume ...`

答え合わせ: `bash scripts/check.sh 5`

<details>
<summary>解答例</summary>

```bash
openstack volume create lab-vol1 --size 1
openstack volume show lab-vol1 -f value -c status          # available になるまで繰り返す

openstack server add volume lab-vm1 lab-vol1
openstack volume show lab-vol1 -c status -c attachments    # in-use, device: /dev/vdb

ssh -i ~/.ssh/lab-key cirros@<Floating IP> 'cat /proc/partitions'   # vdb (1048576 blocks) が増えている

openstack server remove volume lab-vm1 lab-vol1
openstack volume show lab-vol1 -f value -c status          # available に戻るまで待つ

openstack volume snapshot create lab-vol1-snap --volume lab-vol1
openstack volume snapshot list
```

6. `Invalid volume: Volume ... status must be available, but current status is: in-use` で断られる。
   使用中のボリュームは中身が書き換わっている最中かもしれないので、既定では許されない。
   `--force` を付ければ取れるが、ファイルシステムの整合性は保証されない
   (VM 側で書き込みを止めてから取るのが安全)。

</details>
