# 06 インスタンスのスナップショットとイメージ

動いている VM の中身をイメージとして保存し、そこから同じ VM を何台でも作れるようにする。

## 問題

1. `lab-vm1` に SSH し、目印のファイルを作る: `echo hello-from-vm1 > /home/cirros/marker.txt`
2. `lab-vm1` のスナップショットイメージ `lab-vm1-snap` を作り、イメージの状態が `active` になるまで待つ。
3. `lab-vm1-snap` のサイズと、`openstack image list` での見え方 (誰に見えるか) を確かめる。
4. `lab-vm1-snap` から 2 台目の VM `lab-vm2` を起動する (フレーバー `m1.tiny`、ネットワーク `lab-net`、
   セキュリティグループ `lab-sg`、キーペア `lab-key`)。
5. `lab-vm2` に Floating IP を割り当てて SSH し、`marker.txt` が引き継がれていることを確かめる。
6. (考える) スナップショットを取る前に VM の中で `sync` しておくのはなぜか。

## ヒント

- `openstack server image create --name ... --wait`
- `openstack image show -c status -c size -c visibility`

答え合わせ: `bash scripts/check.sh 6`

<details>
<summary>解答例</summary>

```bash
FIP1=$(openstack server show lab-vm1 -f json -c addresses | grep -oE '172\.24\.4\.[0-9]+')
ssh -i ~/.ssh/lab-key cirros@"$FIP1" 'echo hello-from-vm1 > /home/cirros/marker.txt; sync'

openstack server image create lab-vm1 --name lab-vm1-snap --wait
openstack image show lab-vm1-snap -c status -c size -c visibility    # active / private

openstack server create lab-vm2 --image lab-vm1-snap --flavor m1.tiny \
  --network lab-net --security-group lab-sg --key-name lab-key --wait
FIP2=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip lab-vm2 "$FIP2"
ssh -i ~/.ssh/lab-key -o StrictHostKeyChecking=accept-new cirros@"$FIP2" 'cat /home/cirros/marker.txt'
```

3. `visibility` は `private`。作ったプロジェクト (`lab`) の中からしか見えない。
   ほかのプロジェクトにも配るには `shared` にして `openstack image add project` で共有するか、
   admin が `public` にする。
6. 書いたデータはしばらくメモリ上のキャッシュにあり、ディスクにはまだ書かれていないことがある。
   スナップショットはディスクの中身を写すので、`sync` でキャッシュを書き出しておかないと
   新しいファイルが空だったり、無かったりする。

</details>
