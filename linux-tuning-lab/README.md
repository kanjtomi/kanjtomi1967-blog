# linux-tuning-lab — Linux チューニング練習環境 (home RHEL k8s)

CPU / メモリ / ディスク I/O / ネットワークのチューニングを、k8s 上の Pod で安全に試すための一式。
本番経路 (S3 + CloudFront + Lambda) とは無関係。namespace は `tuning-lab`。

## 構成

| もの | 中身 |
|---|---|
| `bench` (Deployment) | 作業用 Pod。`localhost/tuning-tools:local` (Fedora 42 + sysstat, stress-ng, fio, sysbench, strace, htop, numactl, ab, iperf3 など)。上限 CPU 2 / メモリ 1Gi、作業場所 `/scratch` (emptyDir 4Gi) |
| `web` (Deployment + Service) | ネットワーク練習の相手の nginx 1.28.0。上限 CPU 1 / メモリ 128Mi。設定は `nginx/nginx.conf` |
| `scenarios/` | 練習シナリオ。ConfigMap `tuning-scenarios` として `/scenarios` にマウントされる |

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

## 片付け

```bash
kubectl delete namespace tuning-lab
ssh root@192.168.0.200 'crictl rmi localhost/tuning-tools:local; podman rmi localhost/tuning-tools:local'
```
