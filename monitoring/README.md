# 監視 (Prometheus + Grafana)

ホームの RHEL k8s クラスタの CPU・メモリなどをブラウザでグラフ表示する。
[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
を Helm で `monitoring` namespace に入れている。

## 開き方

LAN 内の PC のブラウザで開く:

**http://192.168.0.200:30300**

- ユーザー名: `admin`
- パスワード: RHEL ホスト上のファイルに保存してある(リポジトリには入れていない)

```bash
cat /root/grafana-admin-password.txt
```

## まず見るダッシュボード

左メニュー **Dashboards** から開く。上部の `namespace` / `pod` を選んで絞り込む。

| ダッシュボード | 見られるもの |
|---|---|
| Kubernetes / Compute Resources / Pod | 1 つの Pod の CPU・**CPU スロットリング**・メモリ。perf-lab の試験ではこれ |
| Kubernetes / Compute Resources / Namespace (Pods) | namespace 内の Pod の比較 |
| Kubernetes / Compute Resources / Cluster | クラスタ全体で何がリソースを使っているか |
| Node Exporter / Nodes | ホスト自体の CPU・メモリ・ディスク・ネットワーク |

右上の時間範囲は `Last 15 minutes`、自動更新は `5s` か `10s` にすると負荷試験中に見やすい。

## perf-lab の試験を見る

1. **Kubernetes / Compute Resources / Pod** を開き、`namespace=perf-lab`、`pod=perf-db-...` を選ぶ
2. 別ターミナルで CPU シナリオを流す:

   ```bash
   kubectl -n perf-lab exec deploy/perf-bench -- pgbench -n -f cpu-burn.sql -c 8 -j 8 -T 120
   ```

3. **CPU Usage** が limit の 2 コアで頭打ちになり、**CPU Throttling** が 100% 近くまで跳ね上がる

自分でグラフを作るときは **Explore** に PromQL を入れる:

```promql
# CPU 使用コア数
sum(rate(container_cpu_usage_seconds_total{namespace="perf-lab",pod=~"perf-db.*",container="postgres"}[1m]))

# スロットリング率 (0〜1)
sum(rate(container_cpu_cfs_throttled_periods_total{namespace="perf-lab",pod=~"perf-db.*",container="postgres"}[1m]))
  / sum(rate(container_cpu_cfs_periods_total{namespace="perf-lab",pod=~"perf-db.*",container="postgres"}[1m]))

# メモリ (working set, MiB)
sum(container_memory_working_set_bytes{namespace="perf-lab",pod=~"perf-db.*",container="postgres"}) / 1048576

# OOM kill / 再起動の回数
kube_pod_container_status_restarts_total{namespace="perf-lab"}
```

## 構成

| コンポーネント | ネットワーク | 備考 |
|---|---|---|
| Prometheus | hostNetwork (ホストの 9090) | データは `/glide/prometheus`、保持 7 日 / 最大 15GB |
| node-exporter | hostNetwork (9100) | |
| kube-state-metrics / operator | Pod ネットワーク | |
| Grafana | Pod ネットワーク + NodePort 30300 | 設定は保存しない (Pod を作り直すと手動で作ったダッシュボードは消える) |

Prometheus が hostNetwork なのは、firewalld が Pod → ホスト IP 宛ての通信を拒否するため
(Pod → ClusterIP 経由なら通る)。Prometheus は収集先に IP で直接つなぐので、ホストのネットワークに
置かないと kubelet (10250) と node-exporter (9100) に届かない。Prometheus (9090) と node-exporter (9100)
は firewalld で LAN に開けていないので外からは見えない。外から見えるのは Grafana (30300) だけ。

Alertmanager は入れていない。kube-controller-manager / kube-scheduler / etcd / kube-proxy も、kubeadm が
127.0.0.1 で待ち受けていて収集できないので対象から外している。

## インストール / 更新

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
cd /root/monitoring

# 初回のみ
mkdir -p /glide/prometheus/prometheus-db && chown -R 1000:2000 /glide/prometheus
kubectl create namespace monitoring
kubectl apply -f pv.yaml
umask 077; openssl rand -base64 18 | tr -d '/+=\n' > /root/grafana-admin-password.txt
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-file=admin-password=/root/grafana-admin-password.txt

# インストール・設定変更
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring -f values.yaml
```

アンインストール:

```bash
helm uninstall kps -n monitoring
kubectl delete namespace monitoring
kubectl delete -f pv.yaml      # データは /glide/prometheus に残る (Retain)
```
