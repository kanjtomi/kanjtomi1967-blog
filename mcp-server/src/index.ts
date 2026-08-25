import type { APIGatewayProxyHandlerV2 } from "aws-lambda";
import { searchBlogPosts } from "./rag.js";

/**
 * MCP server for kanjtomi1967.net, deployed as a single Lambda behind an
 * API Gateway HTTP API route: POST /mcp
 *
 * This implements the MCP Streamable HTTP transport in STATELESS mode:
 * - No session ID / no SSE stream — each POST is one JSON-RPC request in,
 *   one JSON-RPC response out. This matches how Lambda naturally works
 *   (no long-lived connections) and is explicitly permitted by the MCP
 *   spec (2025-06-18) for servers that don't need server-initiated pushes.
 * - Only three JSON-RPC methods are implemented, which is all a
 *   read-only, single-tool server needs: initialize, tools/list, tools/call.
 */

const PROTOCOL_VERSION = "2025-06-18";

const TOOL_DEFINITION = {
  name: "search_blog_posts",
  description:
    "Search kanjtomi1967.net's blog posts using semantic (embedding-based) search. " +
    "Returns the most relevant excerpts with their source title and URL. " +
    "Use this to answer questions about the blog's content; do not answer from " +
    "outside knowledge if the question is about something the blog covers.",
  inputSchema: {
    type: "object",
    properties: {
      query: {
        type: "string",
        description: "Natural-language question or search query.",
      },
      top_k: {
        type: "integer",
        description: "Number of excerpts to return (default 4, max 10).",
        minimum: 1,
        maximum: 10,
      },
    },
    required: ["query"],
  },
};

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

function rpcResult(id: JsonRpcRequest["id"], result: unknown) {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id: JsonRpcRequest["id"], code: number, message: string) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

export const handler: APIGatewayProxyHandlerV2 = async (event) => {
  // --- Auth: bearer token, same idea as the x-api-key admin routes on
  // blog-comments — a personal-project-scale gate, not full OAuth. ---
  const authHeader = event.headers?.authorization ?? event.headers?.Authorization;
  const expected = process.env.MCP_BEARER_TOKEN;
  if (!expected || authHeader !== `Bearer ${expected}`) {
    return { statusCode: 401, body: JSON.stringify({ error: "unauthorized" }) };
  }

  let req: JsonRpcRequest;
  try {
    req = JSON.parse(event.body ?? "{}");
  } catch {
    return {
      statusCode: 400,
      body: JSON.stringify(rpcError(null, -32700, "Parse error")),
    };
  }

  const { id, method, params } = req;

  try {
    switch (method) {
      case "initialize":
        return jsonResponse(
          rpcResult(id, {
            protocolVersion: PROTOCOL_VERSION,
            capabilities: { tools: {} },
            serverInfo: { name: "blog-mcp", version: "1.0.0" },
          })
        );

      case "notifications/initialized":
        // Client-sent notification, no response body expected.
        return { statusCode: 202, body: "" };

      case "tools/list":
        return jsonResponse(rpcResult(id, { tools: [TOOL_DEFINITION] }));

      case "tools/call": {
        const toolName = params?.name;
        if (toolName !== "search_blog_posts") {
          return jsonResponse(rpcError(id, -32602, `Unknown tool: ${toolName}`));
        }

        const args = (params?.arguments ?? {}) as { query?: string; top_k?: number };
        if (!args.query) {
          return jsonResponse(rpcError(id, -32602, "Missing required argument: query"));
        }
        const topK = Math.min(Math.max(args.top_k ?? 4, 1), 10);

        const results = await searchBlogPosts(args.query, topK, {
          bucket: process.env.RAG_INDEX_BUCKET!,
          key: "index.json",
          voyageApiKey: process.env.VOYAGE_API_KEY!,
        });

        return jsonResponse(
          rpcResult(id, {
            content: [
              {
                type: "text",
                text: JSON.stringify(results, null, 2),
              },
            ],
          })
        );
      }

      default:
        return jsonResponse(rpcError(id, -32601, `Method not found: ${method}`));
    }
  } catch (err) {
    console.error("MCP handler error", err);
    return jsonResponse(rpcError(id, -32603, "Internal error"));
  }
};

function jsonResponse(body: unknown) {
  return {
    statusCode: 200,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}
