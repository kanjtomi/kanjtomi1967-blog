# openstack-lab — OpenStack 練習環境 (Zadara の DevStack)

Zadara (Ubuntu 24.04, DevStack stable/2026.2) の上で、OpenStack の基本操作を手を動かして覚えるための練習問題一式。
本番経路 (S3 + CloudFront + Lambda) とは無関係。練習はすべて専用プロジェクト `lab` の中で行うので、
DevStack が最初から作る `admin` / `demo` プロジェクトの資源は触らない。

## 環境

| もの | 値 |
|---|---|
| ホスト | Zadara。SSH は `tomi@10.10.10.4` (VLAN 1)。DevStack の `HOST_IP` は `10.10.11.6` (VLAN 10) |
| API / Horizon | `http://10.10.11.6/identity` / `http://10.10.11.6/dashboard` |
| 練習用プロジェクト / ユーザー | `lab` / `labuser` (`scripts/setup-lab.sh` が作る。パスワードは `lab-openrc.sh` の中だけ) |
| 外部ネットワーク | `public` (172.24.4.0/24)。Floating IP はこの範囲から払い出される |
| 外部ネットワークの制約 | `public` は Zadara の中だけの網 (`br-ex`)。**Floating IP には Zadara 上からしか届かない**。ping / SSH は Zadara で打つ |
| イメージ | `cirros-0.6.3-x86_64-disk` (ログインユーザー `cirros`、鍵認証) |
| フレーバー | `m1.nano` (192MB) / `m1.tiny` (512MB, 1GB) / `m1.small` (2GB, 20GB) など。`openstack flavor list` で確認 |
| ボリューム | Cinder LVM (`lvmdriver-1`)。容量は小さいので 1GB 単位で使う |
| クォータ (`lab`) | instances 5 / cores 8 / ram 8192MB / volumes 5 / gigabytes 20 / floating-ips 3 |

## セットアップ (最初に 1 回)

Windows PC からファイルを Zadara に送り、練習用プロジェクトとユーザーを作る。

```bash
scp -i ~/.ssh/"id_rsa(opensssh)" -r openstack-lab tomi@10.10.10.4:~/
ssh -i ~/.ssh/"id_rsa(opensssh)" tomi@10.10.10.4
bash ~/openstack-lab/scripts/setup-lab.sh
```

`setup-lab.sh` は何度実行しても同じ状態になる。作るのは、プロジェクト `lab`、ユーザー `labuser` (ロール `member`)、
クォータ、認証情報ファイル `~/openstack-lab/lab-openrc.sh` (権限 600) の 4 つ。

以後の練習は、Zadara 上で次を実行してから始める。

```bash
cd ~/openstack-lab
source lab-openrc.sh          # プロンプトが (lab) になる
openstack token issue          # 認証が通ることの確認
```

Horizon で操作したいときは、`lab-openrc.sh` の `OS_PASSWORD` を見て `labuser` でログインする
(ドメインは `Default`)。ただし Horizon (10.10.11.6) に Windows PC から届くのは、家のルーターに
`10.10.11.0/24 → 192.168.0.100` の経路を足してから。

## 練習問題

上から順に進める。各問題は前の問題で作ったものを使う。
問題ファイルの最後に、折りたたんだ「解答例」がある。まず自分で考えてから開く。

| # | ファイル | 覚えること |
|---|---|---|
| 01 | [exercises/01-basics.md](exercises/01-basics.md) | CLI の使い方、サービスカタログ、トークン、イメージとフレーバー |
| 02 | [exercises/02-network.md](exercises/02-network.md) | テナントネットワーク、サブネット、ルーター、外部ゲートウェイ |
| 03 | [exercises/03-security-keypair.md](exercises/03-security-keypair.md) | セキュリティグループ、キーペア |
| 04 | [exercises/04-instance.md](exercises/04-instance.md) | インスタンス起動、コンソールログ、Floating IP、SSH |
| 05 | [exercises/05-volume.md](exercises/05-volume.md) | ボリュームの作成・接続・取り外し、ボリュームスナップショット |
| 06 | [exercises/06-snapshot-image.md](exercises/06-snapshot-image.md) | インスタンスのスナップショット、そこからの再起動 |
| 07 | [exercises/07-resize.md](exercises/07-resize.md) | フレーバー変更 (リサイズ) と確定 |
| 08 | [exercises/08-troubleshooting.md](exercises/08-troubleshooting.md) | 失敗の読み方: クォータ超過、届かない Floating IP、ERROR 状態 |

## 答え合わせ

```bash
bash scripts/check.sh 2      # 問題 02 だけ確認
bash scripts/check.sh all    # 02〜07 を全部確認
```

`check.sh` は `lab` プロジェクトの状態を見て、各項目を `OK` / `NG` で表示する。何も変更しない。

## やり直し・後片付け

```bash
bash scripts/cleanup-lab.sh           # lab プロジェクトの中身 (VM・ボリューム・ネットワーク等) を全部消す
bash scripts/cleanup-lab.sh --all     # さらにプロジェクト lab とユーザー labuser も消す
```

消した後に `setup-lab.sh` を実行すれば、最初からやり直せる。

## 知っておくと楽なこと

- **出力を絞る**: `-f value -c 列名` で値だけ取り出せる。例 `openstack server show lab-vm1 -f value -c status`
- **待つ**: `openstack server create ... --wait` を付けると ACTIVE (か ERROR) になるまで戻らない
- **ログ**: サービスのログは `sudo journalctl -u devstack@n-cpu -f` (Nova compute)、
  `devstack@q-svc` (Neutron)、`devstack@c-vol` (Cinder) など。`systemctl list-units 'devstack@*'` で一覧
- **cirros は小さい**: busybox ベースなので `lsblk` などは無い。`cat /proc/partitions` や `ip a` を使う
- **DevStack の再起動に注意**: Zadara を再起動すると DevStack が完全には戻らないことがある。
  戻らないときは `sudo -u stack -i` → `cd devstack` → `./unstack.sh && ./stack.sh` (30〜60 分)
