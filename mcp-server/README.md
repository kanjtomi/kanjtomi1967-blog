# blog-mcp — MCP server for kanjtomi1967.net

Exposes the blog's existing RAG index as an MCP **Tool** (`search_blog_posts`),
so any MCP client (Claude Desktop, Claude Code, etc.) can search the blog
directly instead of going through the `/search/` page.

## How it fits with the existing RAG search

`lambda-rag/` (Java) already does: embed question → retrieve top chunks →
call Claude Haiku → return a synthesized answer. That's built for the
blog's own web UI, where there's no LLM on the *calling* side.

`mcp-server/` (this, Node.js) does only the retrieval half: embed query →
retrieve top chunks → return them raw as JSON. It does **not** call Claude
itself — the MCP client calling this tool (e.g. Claude Desktop) is already
an LLM, so it synthesizes the final answer from the returned excerpts. This
is the idiomatic MCP pattern: a Tool returns data, the model does the
reasoning. Running two nested LLM calls for the MCP path would be wasteful
and would make citations harder to track.

Both Lambdas read the same `index.json` in `www.kanjtomi1967.net-rag-index`
(built by the existing `rag-index/` Jenkins step) — no separate indexing
pipeline needed.

## Protocol notes (why it's built this way)

- **Streamable HTTP, stateless mode.** MCP's HTTP transport supports an
  optional session (`Mcp-Session-Id` header) for servers that need
  server-initiated messages or SSE streaming. This server doesn't need
  either — every `tools/call` is a single self-contained request/response
  — so no session is issued. This also happens to be the only mode that
  works cleanly on Lambda, which has no persistent connections.
- **Three JSON-RPC methods only**: `initialize`, `tools/list`, `tools/call`.
  A read-only single-tool server doesn't need Resources, Prompts, or
  sampling, so they're left out rather than stubbed.
- **Auth**: a bearer token checked against `MCP_BEARER_TOKEN`, the same
  shared-secret pattern as the `x-api-key` admin routes in
  `lambda-comments/`. Fine for a personal project; swap for OAuth 2.1 if
  this is ever exposed to other people's MCP clients.

## Setup

1. `npm install`
2. Build + zip: `npm run package` → produces `mcp-lambda.zip`
3. Add `mcp.tf` to `terraform/`, set `voyage_api_key` and `mcp_bearer_token`
   in `terraform.tfvars` (same gitignored file already used for the RAG
   Lambda's Voyage key)
4. `terraform apply` — creates `blog-mcp` Lambda + its own API Gateway
   HTTP API (`POST /mcp`), reusing the existing `rag_index` S3 bucket
   read-only
5. Add a `Build MCP Server` stage to the Jenkinsfile (before `terraform
   apply`, alongside the existing `Rebuild RAG Index` stage):
   ```
   bat 'cd mcp-server && npm ci && npm run package'
   ```

## Connecting a client (Claude Desktop / Claude Code)

```json
{
  "mcpServers": {
    "kanjtomi-blog": {
      "url": "https://<api-id>.execute-api.ap-northeast-1.amazonaws.com/mcp",
      "headers": {
        "Authorization": "Bearer <mcp_bearer_token value>"
      }
    }
  }
}
```

Once connected, ask Claude something like "kanjtomi1967.net で書いた記事の中に
Jenkins の設定について書いたものはある?" — it should call
`search_blog_posts` and answer grounded in the actual post content, with
links.
