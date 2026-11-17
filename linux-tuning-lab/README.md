# linux-tuning-lab — Linux チューニング練習環境 (home RHEL k8s)

CPU / メモリ / ディスク I/O / ネットワークのチューニングを、k8s 上の Pod で安全に試すための一式。
本番経路 (S3 + CloudFront + Lambda) とは無関係。namespace は `tuning-lab`。

## 構成

| もの | 中身 |
|---|---|
| `bench` (Deployment) | 作業用 Pod。`localhost/tuning-tools:local` (Fedora 42 + sysstat, stress-ng, fio, sysbench, strace, htop, numactl, ab, iperf3 など)。上限 CPU 2 / メモリ 1Gi、作業場所 `/scratch` (emptyDir 4Gi) |
| `web` (Deployment + Service) | ネットワーク練習の相手の nginx 1.28.0。上限 CPU 1 / メモリ 128Mi。設定は `nginx/nginx.conf` |
| `scenarios/` | 練習シナリオ。ConfigMap `tuning-scenarios` として `/scenarios` にマウントされる |
| `study` (Deployment) | 性能の見方を 1 つずつ学ぶ勉強用 Pod。同じイメージ、上限 CPU 1 / メモリ 512Mi、ポート範囲 1000 個。`lesson` コマンド (`study/lesson.sh`、ConfigMap `tuning-study`) |

### 安全のための決まり

- ホストは MariaDB (バッファプール 64G) / ServiceNow / Oracle と共有している。k8s はそれらを知らないので、
  **Pod には必ず limits を付ける**。負荷は全部 cgroup の上限の中で起きる。
- **特権なし**。ホスト全体に効く設定 (`vm.*`, `kernel.*` の sysctl、I/O スケジューラなど) は触れない。
  変えるのは「Pod の cgroup の上限」「Pod 単位の safe sysctl (`net.ipv4.ip_local_port_range` など)」
  「nginx の設定」だけ。
- `/scratch` は `/glide` 上にあり、MariaDB / ServiceNow / kubelet と共有している。`/glide` は 2026-11-07 に
  USB の Samsung T5 から内蔵 NVMe (`/home/glide` の bind mount) に移した。下の 03 の表は T5 時代の値。
  fio は 1 テスト 10 秒・1G 程度に留める。

## セットアップ

```bash
# 1. ツール入りイメージをホストでビルドし、containerd に入れる (数分)
ssh root@192.168.0.200 'bash -s' < linux-tuning-lab/build-image.sh

# 2. デプロイ
kubectl apply -k linux-tuning-lab
kubectl -n tuning-lab rollout status deploy/bench

# 3. 作業 Pod に入る
kubectl -n tuning-lab exec -it deploy/bench -- bash
```

Windows の Git Bash から `kubectl exec ... -- /scenarios/...` と打つと、`/scenarios` が
`C:/Program Files/Git/scenarios` に書き換えられて失敗する。`MSYS_NO_PATHCONV=1 kubectl ...` にするか、
`exec -it ... -- bash` で中に入ってから実行する。

## 勉強用コンテナ (study) — 性能の見方レッスン

```bash
kubectl -n tuning-lab exec -it deploy/study -- bash
lesson        # 一覧
lesson 1      # 負荷を起こす → 問題が出る → (別の端末で調べる) → Enter で実測値と解説 → 自動で片付け
```

各レッスンは USE (使用率・飽和・エラー) のどれを、どのコマンドで見るかを 1 つずつ扱う。
`-it` なしで実行すると問題のところで待たずに進む (`WAIT=秒` で待ち時間を変えられる)。

| # | テーマ | 2026-11-15 の実測 |
|---|---|---|
| 1 | load が高い = CPU 不足? | load 3.3、D 状態 8 個、Pod の CPU 0.04 コア。vmstat の b 列は 0 (ジャーナル待ちは数えられない) |
| 2 | CPU の飽和とスロットリング | ホストは 89% 空き、3 プロセスとも %usr 33 / **%wait 67**、50 周期中 50 周期スロットリング |
| 3 | 平均は正常でも p99 が悪い | バッチと同居で p50 8→7 ms (変わらず)、**平均 8.9→22 ms、p99 18→80 ms** |
| 4 | コンテナのメモリはどこを見る? | `free` はホストの 93GB を表示。300MB は 2 回目 0.25→0.06 秒、700MB は 2 回目も速くならず refault 17.9 万 |
| 5 | OOMKilled | 700MB 確保で exec が exit 137、RESTARTS 1、`lastState.terminated.reason: OOMKilled` |
| 6 | %util は限界を表す? | qd1: 11.5k r/s・%util 90%、qd32: **116k r/s・%util 85%** (aqu-sz 0.9 → 10) |
| 7 | 余っているのに接続できない | keep-alive は 3000/3000 成功、毎回 close は 996 成功 / 2004 失敗 (EADDRNOTAVAIL)、TIME_WAIT 1000 |

レッスン 5 はコンテナを再起動させるので最後にやる。総合問題は bench Pod の `/scenarios/mystery.sh`。

## vmstat / iostat を読む練習 (drill)

study Pod で `drill` と打つと、5 種類の負荷 (CPU / fsync / 順次読み / 順次書き / 4k ランダム読み) の
どれか 1 つを裏で起こし、負荷前と負荷中の `vmstat` と `iostat -dx` だけを見せる。A〜E から当てると、
決め手になった列を解説する。`drill vmstat` / `drill iostat` で片方だけ、`drill fsync` などで種類を指定。

2026-11-16 の実測 (負荷中、nvme0n1):

| 負荷 | vmstat の決め手 | iostat の決め手 |
|---|---|---|
| CPU (stress-ng、上限 1 コア) | us +5〜10%、r が増える、bi/bo 変わらず | 変化なし |
| 4k + fdatasync × 6 | b 2、wa 4%、bo 5.6MB/s | w/s 1,282・wkB/s 5,878 → **wareq-sz 4.6k**、**f/s 547**、%util 96% |
| 順次読み 300MB/s | **bi 307,200** | r/s 600・rareq-sz 512・r_await 0.47ms・%util 17% |
| 順次書き 300MB/s | **bo 307,300** | w/s 616・wareq-sz 499・%util 11% |
| 4k ランダム読み 30k IOPS | bi 120,000、in/cs が大きく増える | **r/s 30,001・rareq-sz 4**・aqu-sz 2.7・%util 63% |

## トラブルシューティング練習 (trouble)

同じ study Pod で、「動かない」「エラーが出る」系の障害を起こして直す練習。対象は小さな Web サービス
`myapp` (`study/myapp.py`、`myapp start|stop|status|log`)。`/health` は「設定を読む → `/data/myapp` に
書く → web Service を名前で呼ぶ」をするので、どこが壊れても 500 か起動失敗になる。

```bash
kubectl -n tuning-lab exec -it deploy/study -- bash
trouble start 1      # 障害を起こす。チケット (顧客の申告) が出る
trouble hint         # 打つたびにヒントが 1 段ずつ増える
trouble check        # 直ったか判定 (/health が 200 か、など)
trouble answer       # 原因・調べ方・直し方・再発防止
trouble reset        # 全部元に戻す
```

| # | チケット | 原因 | 決め手 |
|---|---|---|---|
| 1 | 再起動したら上がらない | 残っていた `python3 -m http.server` が 8080 を使用 | ログの `Address already in use` → `ss -ltnp` |
| 2 | ディスク一杯なのにファイルが見つからない | 削除済みだが開かれたままのファイル (64Mi の tmpfs `/data`) | `df` 100% / `du` 0 → `ls -l /proc/*/fd \| grep deleted` |
| 3 | 相手は動いているのにつながらない | `/etc/resolv.conf` の nameserver が 192.0.2.53 | `getent hosts` 失敗 → `/etc/resolv.conf`。`sed -i` は bind mount なので失敗する (上書きで直す) |
| 4 | uid 1000 にしたら起動しない | 設定ファイル 600 と、データディレクトリ 755 root の **2 段階** | `Permission denied` → `ls -l`。1 つ直したらもう一度試す |
| 5 | しばらくするとエラーしか返さない | fd リーク + 上限 64 | `Too many open files` → `/proc/<PID>/limits` と `ls /proc/<PID>/fd \| wc -l` → `prlimit` |

2026-11-16 に 5 つとも「壊す → ヒントどおりに直す → `trouble check` が ✓」まで確認済み。
答えと元の設定は `/tmp/.trouble` にあるが、見ない約束。

## シナリオ

設定 (YAML / nginx.conf) を変えたら `kubectl apply -k linux-tuning-lab`。ConfigMap の変更が
Pod の `/scenarios` に反映されるまで最大 1 分ほどかかる。Deployment の変更 (limits, sysctls) は Pod が作り直される。

どのシナリオの最中でも、別の端末から `/scenarios/observe.sh 2` で cgroup の状態
(`cpu.stat`, `memory.stat`, `memory.events`, `io.stat`) を 2 秒ごとに見られる。

### 01 CPU: `limits.cpu` とスロットリング

```bash
/scenarios/01-cpu-throttle.sh 1 10    # ワーカー 1、10 秒
/scenarios/01-cpu-throttle.sh 4 10    # ワーカー 4 (上限 2 コアを超える)
```

2026-11-07 の結果: ワーカー 1 は 0.99 コア・スロットリング 0%。ワーカー 4 は **2.01 コアで頭打ち、
100 周期中 85 周期 (84%) でスロットリング**。仕事量 (bogo ops) もほとんど増えない。

試すこと: `k8s/bench.yaml` の `limits.cpu` を `"1"` / `"4"` に変える。`requests` だけにして limit を外すと
どうなるか。別の端末で `mpstat -P ALL 1` / `pidstat -u 1`。

### 02 メモリ: ページキャッシュと OOM

```bash
/scenarios/02-memory.sh cache 1200 3   # 1200MB のファイルを 3 回読む (上限 1Gi より大きい)
/scenarios/02-memory.sh cache 600 3    # 600MB (上限に収まる)
/scenarios/02-memory.sh anon 700       # anon メモリ 700MB を確保
/scenarios/02-memory.sh anon 1300      # 上限超え → コンテナごと OOMKilled
```

2026-11-07 の結果:

| | 1 回目 | 2 回目 | 3 回目 |
|---|---|---|---|
| 1200MB (載りきらない) | 2.42 秒, ディスクから 1200MB, refault 307k | 2.36 秒, 1199MB, 307k | 2.38 秒, 1199MB, 307k |
| 600MB (載る) | 0.12 秒, 0MB | 0.11 秒, 0MB | 0.12 秒, 0MB |

上限より大きい作業セットは、何度読んでもキャッシュに残らずディスクから読み直す
(`workingset_refault_file` が増え続ける)。**2026-11-07 に Multus (上限 50Mi) が `/glide` を 40MB/s で
読み続けて USB SSD を詰まらせた障害と同じ現象**。

`anon` で上限を超えると、k8s 1.28 以降 (cgroup v2) は `memory.oom.group=1` なので、一番大きい
プロセスだけでなく **コンテナごと OOMKilled** になって再起動する (exec も exit 137 で切れる)。
外から `kubectl -n tuning-lab get pod -l app=bench` の RESTARTS と `lastState.terminated.reason: OOMKilled` で確認する。

### 03 ディスク I/O: fio

```bash
/scenarios/03-disk-io.sh 10 1G
```

2026-11-07 の結果 (`/glide` = Samsung T5 を USB 3, 10Gbps に挿し直した後):

| テスト | 帯域 | IOPS | 遅延 p50 / p99 |
|---|---|---|---|
| 順次書き込み 1M, qd8, direct | 489 MB/s | 489 | 15.9 / 20.1 ms |
| 順次読み込み 1M, qd8, direct | 503 MB/s | 503 | 14.9 / 19.0 ms |
| ランダム読み込み 4k, qd1 | 17.6 MB/s | 4,497 | 173 / 247 us |
| ランダム読み込み 4k, qd32 | 86.0 MB/s | 22,017 | 1.4 / 4.5 ms |
| ランダム書き込み 4k, 毎回 fsync | 0.6 MB/s | 160 | 92 us / 2.7 ms |

同じテストを NVMe (970 EVO Plus) に移した後に実行すると: 順次書き込み 1,418 MB/s、順次読み込み 3,250 MB/s、
4k qd1 11,634 IOPS、4k qd32 124,168 IOPS、fsync 毎回 163 IOPS。**fsync だけは USB SSD とほぼ同じ**
(フラッシュの完了待ちがデバイス側で律速するため)。

読み方: キュー深さを上げると IOPS は 5 倍になるが 1 件あたりの遅延も伸びる。fsync を毎回入れると
IOPS は 2 桁落ちる (DB のコミットが遅い理由)。試すこと: `--direct=0` (ページキャッシュ経由)、
bs を 4k / 64k / 1M で比較、別の端末で `iostat -x 1`。

### 04 ネットワーク: keep-alive とエフェメラルポート枯渇

```bash
/scenarios/04-network.sh 5000 20
```

`bench` Pod の `net.ipv4.ip_local_port_range` は **わざと `61000 61999` (1000 ポート) に絞ってある**。

2026-11-07 の結果:

| | 結果 |
|---|---|
| ab keep-alive あり | 24,227 req/s, 平均 0.83 ms, 失敗 0 |
| ab keep-alive なし | 3,555 req/s, 平均 5.6 ms, 失敗 0 (nginx が先に close するので TIME_WAIT は nginx 側) |
| client-close.py (クライアントが先に close) | **成功 974 / 失敗 4,026 "Cannot assign requested address"**、TIME_WAIT 1000 (= ポート数) |
| 同じものをポート範囲 `32768 60999` の Pod で | 成功 5,000 / 失敗 0 |

先に close した側に TIME_WAIT (約 60 秒) が残る。クライアントが毎回接続し直すと、同じ宛先への
エフェメラルポートを使い切って新しい接続が張れなくなる。

試すこと:
- `k8s/bench.yaml` の範囲を `"32768 60999"` に広げて apply し直す (Pod が作り直される)。
- 60 秒待ってからもう一度 (TIME_WAIT が消えると通るようになる)。
- `nginx/nginx.conf` の `worker_processes` / `worker_connections` / `keepalive_timeout` を変える。
- `ab -k -n 50000 -c 600 http://web/` で `worker_connections 512` を超える同時接続をかける。

`net.core.somaxconn` や `net.ipv4.tcp_tw_reuse` は namespaced だが k8s では "unsafe" sysctl 扱いで、
kubelet の `allowedUnsafeSysctls` を変えないと Pod から設定できない (クラスタ設定の変更になるので未対応)。

### 05 I/O 待ちで load average が上がる (fsync)

```bash
/scenarios/05-iowait-load.sh 16 60    # 4k 書き込み + 毎回 fdatasync のプロセス 16 個、60 秒
```

5 秒ごとに load average・D 状態のプロセス数・Pod の CPU 使用量・ディスクの w/s / wkB/s / w_await / %util
(`/proc/diskstats` から iostat -x と同じ計算) を出す。load average はホスト全体の値。

2026-11-15 の結果 (16 プロセス、20 秒): load1 0.38 → 5.02 (1 分平均なので 60 秒続ければもっと上がる)、
D 状態 16、**Pod の CPU 0.1 コア**。ディスクは w/s ~1,800・**wkB/s ~7MB/s で %util 99%**、w_await 2.7 ms。
fio から見ると 800 書き込み/s、fdatasync 1 回 p50 20 ms。fdatasync はアプリの 1 書き込みに対して
ジャーナル込みで 2 回強のデバイス書き込みになる。

読み方: load average は「実行中 + 実行待ち + D 状態 (主に I/O 待ち)」の数なので、CPU が暇でも上がる。
帯域は小さいのに %util が 100% 近いのは、1 件ずつ flush の完了を待っているから。**NVMe の %util は
「何か 1 件でも処理中だった時間の割合」で、並列に処理できる余力は表さない**ので、限界かどうかは
w_await と、並列を増やしたときに w/s が伸びるかで判断する。

### 原因当て (mystery)

5 種類の問題からランダムに 1 つを裏で起こし、何が起きているかを当てる練習。

```bash
/scenarios/mystery.sh start 10   # 10 分で自動停止
#   ... uptime / top / vmstat 1 / pidstat -u -d -r 1 / iostat -x 1 / ss -s / /tmp/app.log / observe.sh 2
/scenarios/mystery.sh answer     # 正解と、見るべきだった指標
/scenarios/mystery.sh stop
```

| 問題 | 中身 | 決め手になる指標 (2026-11-15 に確認) |
|---|---|---|
| cpu | busy loop 4 プロセス (上限 2 コア) | python3 4 つが各 50% で頭打ち、`nr_throttled` が増える |
| fsync | 4k + fdatasync を 12 プロセス | load ~7、D 状態 12、iostat の %util 高・帯域小 |
| cache | 1200MB を繰り返し読む | 毎回 1.2 秒で速くならない、`workingset_refault_file` 増加 |
| memory | anon 850MB + 300MB を繰り返し読む | `memory.current` が上限に張り付く、anon 900MB / file 160MB、refault 増加、OOM はなし |
| ports | 毎回接続してクライアントから close | TIME_WAIT 1000、ログに `Cannot assign requested address` |

アプリは全部 `python3 /scenarios/app.py` (中身は環境変数 `MODE`) なので、ps の見た目では区別できない。
`/tmp/.mystery` に答えが入っているが、それは見ない約束。

### iSCSI の性能 (Zadara の LUN)

`iscsi-pv-lab/bench` の `iscsi-bench` Pod で、iSCSI の LUN とローカル NVMe を同じ fio で比べる。
手順と結果は [`../iscsi-pv-lab/README.md`](../iscsi-pv-lab/README.md) の「性能の練習」。

## 片付け

```bash
kubectl delete namespace tuning-lab
ssh root@192.168.0.200 'crictl rmi localhost/tuning-tools:local; podman rmi localhost/tuning-tools:local'
```
