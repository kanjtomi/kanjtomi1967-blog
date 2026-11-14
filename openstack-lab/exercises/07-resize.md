# 07 リサイズ (フレーバー変更)

VM の CPU・メモリ・ディスクの大きさを後から変える。リサイズは「変更 → 確認 → 確定」の 2 段階になっている。

## 問題

1. `lab-vm2` のいまのフレーバーとメモリ量を確かめる (VM の中で `free -m`)。
2. `lab-vm2` を `m1.small` にリサイズし、状態が `VERIFY_RESIZE` になるまで待つ。
3. この時点で VM の中のメモリ量を確かめる。
4. リサイズを確定し、状態が `ACTIVE`・フレーバーが `m1.small` になったことを確かめる。
5. クォータの使用量を見て、vCPU とメモリの使用量がどう変わったか確かめる (変わらないものもある。なぜか)。
6. (考える) `VERIFY_RESIZE` の状態で確定せずに取り消すと、どうなるか。

## ヒント

- `openstack server resize --flavor ... --wait`
- `openstack server resize confirm` / `openstack server resize revert`
- `openstack quota show --usage` (使用量も表示する)

答え合わせ: `bash scripts/check.sh 7`

<details>
<summary>解答例</summary>

```bash
openstack server show lab-vm2 -c flavor
FIP2=$(openstack server show lab-vm2 -f json -c addresses | grep -oE '172\.24\.4\.[0-9]+')
ssh -i ~/.ssh/lab-key cirros@"$FIP2" 'free -m'          # 約 460MB

openstack server resize lab-vm2 --flavor m1.small --wait
openstack server show lab-vm2 -f value -c status        # VERIFY_RESIZE
ssh -i ~/.ssh/lab-key cirros@"$FIP2" 'free -m'          # 約 1960MB (もう大きくなっている)

openstack server resize confirm lab-vm2
openstack server show lab-vm2 -c status -c flavor        # ACTIVE / m1.small
openstack quota show --usage | grep -E ' (cores|ram) '     # In Use 列: cores 2→2, ram 1024→2560
```

リサイズは VM を一度止めて、新しい大きさで作り直す。そのため実行中に SSH が一時的に切れる。

5. メモリは 512MB → 2048MB で 1536MB 増えるが、vCPU は `m1.tiny` も `m1.small` も 1 なので変わらない。

6. `openstack server resize revert lab-vm2` で取り消すと、元のフレーバー (`m1.tiny`) のディスクとメモリに戻る。
   確定までは元のディスクも残っているので戻せる。確定 (confirm) すると元のディスクが消え、もう戻せない。
   放っておいても一定時間後に自動で確定される設定にできる (`resize_confirm_window`)。

</details>
