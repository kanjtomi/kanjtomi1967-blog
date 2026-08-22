# mcp-blog-sample

MCP(Model Context Protocol)学習用の、最小構成のMCPサーバーです。
このブログの `content/posts/*.md` を読み取り、3つのツールとして公開します。
本番のHugoビルド/Jenkinsパイプラインとは無関係の、独立した学習用コードです。

## 公開しているツール

- `list_posts(include_drafts=False)` — 記事一覧(title, date, tags, slug, draft)
- `get_post(slug)` — 1記事の全文を取得
- `search_by_tag(tag)` — 指定タグを持つ記事を検索

## セットアップ

```bash
cd mcp-blog-sample
python -m venv .venv
.venv\Scripts\activate          # Windows
pip install -r requirements.txt
```

## 動作確認(MCP Inspector)

`mcp[cli]` に含まれる Inspector で、ブラウザからツールを叩いて動作確認できます。

```bash
mcp dev server.py
```

表示されるURLをブラウザで開き、`list_posts` などを実行してみてください。

## Claude Desktopに接続する場合

`claude_desktop_config.json` に以下を追加します(パスは環境に合わせて書き換え):

```json
{
  "mcpServers": {
    "blog-posts": {
      "command": "F:\\Claude\\blog-project\\mcp-blog-sample\\.venv\\Scripts\\python.exe",
      "args": ["F:\\Claude\\blog-project\\mcp-blog-sample\\server.py"]
    }
  }
}
```

Claude Desktopを再起動すると、`list_posts` / `get_post` / `search_by_tag` が
ツールとして使えるようになります。

## 仕組みメモ

- `MCPServer`(`mcp.server.mcpserver`、MCP SDK 2.0以降。旧称 `FastMCP`)を
  使うと、Pythonの関数に `@mcp.tool()` を付けるだけでMCPツールとして
  公開できます。docstringがそのままツールの説明になり、型ヒントから
  入力スキーマが自動生成されます。
- `mcp.run()` はデフォルトで **stdio トランスポート**を使います。つまり
  クライアント(Claude Desktopなど)がこのプロセスを子プロセスとして起動し、
  標準入出力でJSON-RPCをやり取りします。単独で `python server.py` を実行
  すると標準入力からのメッセージを待ち続けるだけなので、動作確認は
  `mcp dev server.py` を使うのが簡単です。
