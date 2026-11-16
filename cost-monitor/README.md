# cost-monitor — AWS の料金を監視するコンテナ (home RHEL k8s)

2026-11-14 に S3 PV ラボが S3 を月 ~$100 まで使っていたのに、気づくのが遅れた。その反省で作った。
AWS Cost Explorer から 1 日 1 回、サービス別・日別の料金を取り、ダッシュボードと Prometheus メトリクスで出す。

| もの | 値 |
|---|---|
| ダッシュボード | http://192.168.0.200:30480/ (NodePort。LAN から開ける) |
| JSON / メトリクス | `/status`、`/metrics` (Prometheus が 5 分ごとに取る。ServiceMonitor `cost-monitor`) |
| namespace | `cost-monitor` (Deployment / Service / ConfigMap / Secret / ServiceMonitor) |
| イメージ | `localhost/cost-monitor:local` (python:3.12-alpine、標準ライブラリだけ。boto3 なし) |
| IAM | ユーザー `k8s-cost-monitor`、`ce:GetCostAndUsage` と `ce:GetCostForecast` だけ (Terraform、`terraform/`) |
| 鍵 | Secret `aws-cost-monitor-creds` にだけ入っている。Terraform の state (gitignore 済み) にも残る |

## 料金について

**Cost Explorer API は 1 リクエスト $0.01**。1 回の取得で 2 リクエスト (日別サービス別 + 予測)、
24 時間ごとなので月 ~$0.6。Pod を再起動するとその場で 1 回取得する (+$0.02)。`/metrics` の
スクレイプやダッシュボードの表示は、前回取った値を返すだけなので料金はかからない。
`aws_cost_api_requests_total` で、この Pod が呼んだ回数を見られる。

## 表示されるもの

- 今月の実績、**今月の見込み** (実績 + データのある最後の 1 日の料金 × 残り日数)、AWS の予測、予算、先月
- アラート:
  - 見込みが予算 (`MONTHLY_BUDGET_USD`、既定 $10) を超えた
  - あるサービスの 1 日の料金が `DAILY_ALERT_USD` (既定 $1) 以上で、直前 7 日の中央値の `SPIKE_RATIO` (既定 2) 倍以上
  - あるサービスの 1 日の料金が `DAILY_ALERT_USD` の 3 倍以上 (ずっと高いまま)
- サービス別・日別の表 (直近 14 日、色が濃いほど高い) と、サービスごとの今月の合計

アラートはダッシュボードとログ (`kubectl -n cost-monitor logs deploy/cost-monitor`) と
`aws_cost_alerts` メトリクスに出る。Alertmanager は無効なので通知は飛ばない。

### 読み方の注意

- 日付は UTC。**Cost Explorer は 1〜2 日遅れる**ので、直近の日は空になる。「データは YYYY-MM-DD まで」を見る。
- **AWS の予測は過去の傾向から外挿する**ので、急に止めた直後は高く出る。2026-11-16 の初回は、S3 を
  止めた後なのに AWS の予測が $115、最後の 1 日のペースでは $76 (今月はすでに実績 $57)。予算アラートは
  見込み (最後の 1 日のペース) で判定する。
- Route 53 のホストゾーン料金と Tax は月初にまとめて付くので、日別の表では空、今月の列だけに出る。

## 作り方

```bash
# 1. IAM ユーザーと鍵 (local state)
cd cost-monitor/terraform && terraform init && terraform apply

# 2. 鍵を Secret に入れる (画面に出さない)
kubectl create namespace cost-monitor
kubectl -n cost-monitor create secret generic aws-cost-monitor-creds \
  --from-literal=AWS_ACCESS_KEY_ID="$(terraform output -raw access_key_id)" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(terraform output -raw secret_access_key)"

# 3. イメージを RHEL でビルドして containerd に入れる (Windows の Git Bash から)
cd .. && tar cf - Dockerfile monitor.py | ssh root@192.168.0.200 'rm -rf /root/cost-monitor && mkdir -p /root/cost-monitor && tar xf - -C /root/cost-monitor && cd /root/cost-monitor && podman build -t localhost/cost-monitor:local . && podman save localhost/cost-monitor:local -o /tmp/cm.tar && ctr -n k8s.io images import /tmp/cm.tar && rm /tmp/cm.tar'

# 4. デプロイ
kubectl apply -f k8s/cost-monitor.yaml
```

設定 (予算・閾値・間隔) は `k8s/cost-monitor.yaml` の ConfigMap。変えたら apply して
`kubectl -n cost-monitor rollout restart deploy/cost-monitor` (その場で 1 回取得する)。

## Grafana で見る

http://192.168.0.200:30300 の Explore で、例えば:

- `aws_cost_month_to_date_usd` と `aws_cost_pace_month_usd` と `aws_cost_monthly_budget_usd`
- `topk(5, aws_cost_daily_usd)` (サービス別、最後のデータの日)

Grafana は状態を持たないので、作ったダッシュボードは Pod が作り直されると消える (monitoring/README.md)。

## 片付け

```bash
kubectl delete -f cost-monitor/k8s/cost-monitor.yaml   # namespace ごと Secret も消える
cd cost-monitor/terraform && terraform destroy         # IAM ユーザーと鍵
ssh root@192.168.0.200 'crictl rmi localhost/cost-monitor:local; podman rmi localhost/cost-monitor:local'
```
