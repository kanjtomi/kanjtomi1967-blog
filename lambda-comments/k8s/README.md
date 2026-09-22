# comments-service on Kubernetes (learning / staging replica)

これは本番の AWS Lambda (`Handler.java`, Terraform管理) を置き換えるものではありません。
同じビジネスロジックを、`HttpAdapter.java` という薄いアダプタ経由でプレーンなHTTPサーバーとして
動かし、自宅のRHEL k8sクラスタ上で **k8sの学習・検証用レプリカ** として動かすためのものです。

本番トラフィックには一切関与しません。namespace `blog-staging` に隔離されており、
Service もデフォルトで `ClusterIP`（クラスタ外には公開しない）にしています。

## 前提

- RHELノード上にビルド用のコンテナツール（`podman` 推奨、RHELに標準搭載）があること
- このリポジトリ（`kanjtomi/kanjtomi1967-blog`、public）を RHEL ノード上に clone してあること
- 単一ノードクラスタで、外部レジストリを使わず `containerd` に直接イメージを読み込む前提

```bash
sudo dnf install -y podman
git clone https://github.com/kanjtomi/kanjtomi1967-blog.git
cd kanjtomi1967-blog/lambda-comments
```

## 1. イメージのビルド

```bash
podman build -t comments-service:local .
```

## 2. イメージを containerd に直接読み込む(レジストリ不要)

```bash
podman save comments-service:local -o /tmp/comments-service.tar
sudo ctr -n k8s.io images import /tmp/comments-service.tar
sudo ctr -n k8s.io images ls | grep comments-service
```

`k8s/deployment.yaml` は `imagePullPolicy: Never` にしているので、この読み込み済みイメージを
そのまま使います(外部レジストリへのpushは不要)。

## 3. Secretの作成(このファイルには含めていません)

`www.kanjtomi1967.net-comments` バケットに対して `s3:GetObject`/`s3:PutObject`/`s3:ListBucket` のみを
許可した、**専用の**IAMユーザーを新規作成してください(既存の `aws-blog-deploy-creds` は使い回さないこと -
このクラスタはAWSの外にあるため、より広い権限のクレデンシャルを持ち出すのは避けたい)。

```bash
kubectl apply -f namespace.yaml

kubectl create secret generic comments-secrets -n blog-staging \
  --from-literal=TURNSTILE_SECRET=<Cloudflare Turnstileのsecret key> \
  --from-literal=ADMIN_API_KEY=<任意のテスト用admin key> \
  --from-literal=AWS_ACCESS_KEY_ID=<上記IAMユーザーのアクセスキー> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<上記IAMユーザーのシークレットキー>
```

## 4. デプロイ

```bash
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get pods -n blog-staging
```

## 5. 動作確認(クラスタ外からはアクセスできない前提なので port-forward を使う)

```bash
kubectl port-forward -n blog-staging svc/comments-service 8080:80
```

別ターミナル(Windows PowerShellでもOK)から:

```powershell
# ヘルスチェック
curl http://localhost:8080/health

# コメント投稿(Turnstileの検証があるため、実際のトークンがないと400になります - 動作確認用)
curl -X POST http://localhost:8080/comments `
  -H "Content-Type: application/json" `
  -d '{\"slug\":\"test-post\",\"author\":\"tester\",\"body\":\"hello from k8s\",\"turnstileToken\":\"dummy\"}'

# 承認済みコメント一覧(空でもOK)
curl "http://localhost:8080/comments?slug=test-post"

# 管理API
curl http://localhost:8080/admin/pending -H "x-api-key: <ADMIN_API_KEYの値>"
```

## 後始末

```bash
kubectl delete namespace blog-staging
```

namespaceを削除すれば、このレプリカに関するリソースは全て消えます(S3バケットの実データには
影響しません)。
