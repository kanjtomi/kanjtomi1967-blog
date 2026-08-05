# コメント承認 コマンド集

`terraform output comments_api_endpoint` で取得したURLを `API_BASE` に、
`admin_api_key`(terraform.tfvarsで設定した値)を `API_KEY` に置き換えて使用してください。

## 未承認コメントの一覧を見る

```bash
curl -s -H "x-api-key: <API_KEY>" "<API_BASE>/admin/pending" | jq
```

## コメントを承認する

上記で確認した `slug` と `id` を使います。

```bash
curl -s -X POST \
  -H "x-api-key: <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"slug": "test-post", "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}' \
  "<API_BASE>/admin/approve" | jq
```

## Windows PowerShellの場合

```powershell
$apiKey = "<API_KEY>"
$apiBase = "<API_BASE>"

# 一覧
Invoke-RestMethod -Uri "$apiBase/admin/pending" -Headers @{ "x-api-key" = $apiKey }

# 承認
$body = @{ slug = "test-post"; id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" } | ConvertTo-Json
Invoke-RestMethod -Uri "$apiBase/admin/approve" -Method Post -Headers @{ "x-api-key" = $apiKey } -ContentType "application/json" -Body $body
```
