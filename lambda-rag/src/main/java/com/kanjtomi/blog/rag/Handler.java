package com.kanjtomi.blog.rag;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.anthropic.client.AnthropicClient;
import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.anthropic.models.beta.AnthropicBeta;
import com.anthropic.models.beta.messages.BetaMcpToolset;
import com.anthropic.models.beta.messages.BetaMessage;
import com.anthropic.models.beta.messages.BetaRequestMcpServerUrlDefinition;
import com.anthropic.models.beta.messages.BetaTextBlock;
import com.anthropic.models.beta.messages.MessageCreateParams;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.services.s3.S3Client;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Single Lambda behind the RAG "ask this blog" search, with two routes:
 *   POST /ask  { "question": "...", "turnstileToken": "..." }
 *     -> { "answer": "...", "sources": [{"title": "...", "url": "..."}] }
 *     Calls Claude via the MCP connector; Claude decides whether/how to
 *     call the search_blog_posts tool exposed below rather than us
 *     pre-fetching context by hand.
 *   POST /mcp  (JSON-RPC 2.0, called by Anthropic's backend only, not the browser)
 *     A minimal, stateless MCP Streamable-HTTP server exposing one tool,
 *     search_blog_posts, backed by the same Voyage/IndexStore retrieval
 *     that used to live directly in ask().
 */
public class Handler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final S3Client S3 = S3Client.create();
    private static final AnthropicClient CLAUDE = AnthropicOkHttpClient.fromEnv();

    private static final String BUCKET_NAME = System.getenv("BUCKET_NAME");
    private static final String INDEX_KEY = System.getenv().getOrDefault("INDEX_KEY", "index.json");
    private static final String TURNSTILE_SECRET = System.getenv("TURNSTILE_SECRET");
    private static final String VOYAGE_API_KEY = System.getenv("VOYAGE_API_KEY");
    private static final String MCP_SHARED_SECRET = System.getenv("MCP_SHARED_SECRET");
    private static final String MCP_SERVER_URL = System.getenv("MCP_SERVER_URL");

    private static final int MAX_QUESTION_LEN = 300;
    private static final int TOP_K = 4;

    private static final String SYSTEM_PROMPT = """
            You are a helpful assistant answering questions about a personal technical blog \
            (topics: AWS, Hugo, Jenkins, AI, infrastructure). Use the search_blog_posts tool to \
            find relevant excerpts before answering; answer the user's question using only \
            information returned by that tool. If the tool doesn't return enough information to \
            answer, say plainly that the blog doesn't cover this topic yet - do not use outside \
            knowledge to fill the gap. Respond in the same language as the question. Keep the \
            answer concise.""";

    private static final Pattern SOURCE_PATTERN =
            Pattern.compile("### (.+)\\R+Source: (\\S+)");

    // Loaded once per Lambda execution environment (cold start), reused across warm invocations.
    private static volatile IndexStore indexStore;

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        String routeKey = event.getRouteKey();
        try {
            if ("POST /ask".equals(routeKey)) {
                return ask(event);
            }
            if ("POST /mcp".equals(routeKey)) {
                return mcp(event);
            }
            return jsonResponse(404, Map.of("error", "not found"));
        } catch (Exception e) {
            context.getLogger().log("Unhandled error: " + e);
            return jsonResponse(500, Map.of("error", "internal server error"));
        }
    }

    // ---------------------------------------------------------------------
    // POST /ask - browser-facing endpoint
    // ---------------------------------------------------------------------

    private APIGatewayV2HTTPResponse ask(APIGatewayV2HTTPEvent event) throws Exception {
        JsonNode body = MAPPER.readTree(event.getBody() == null ? "{}" : event.getBody());
        String question = trimToNull(body.path("question").asText(null));
        String turnstileToken = body.path("turnstileToken").asText(null);

        if (question == null) {
            return jsonResponse(400, Map.of("error", "question is required"));
        }
        if (question.length() > MAX_QUESTION_LEN) {
            return jsonResponse(400, Map.of("error", "question too long"));
        }

        String remoteIp = event.getRequestContext() != null && event.getRequestContext().getHttp() != null
                ? event.getRequestContext().getHttp().getSourceIp()
                : null;
        if (!TurnstileVerifier.verify(TURNSTILE_SECRET, turnstileToken, remoteIp)) {
            return jsonResponse(400, Map.of("error", "captcha verification failed"));
        }

        MessageCreateParams params = MessageCreateParams.builder()
                .model("claude-haiku-4-5")
                .maxTokens(1024L)
                .system(SYSTEM_PROMPT)
                .addUserMessage(question)
                .addMcpServer(BetaRequestMcpServerUrlDefinition.builder()
                        .url(MCP_SERVER_URL)
                        .name("blog-search")
                        .authorizationToken(MCP_SHARED_SECRET)
                        .build())
                .addTool(BetaMcpToolset.builder().mcpServerName("blog-search").build())
                .addBeta(AnthropicBeta.MCP_CLIENT_2025_11_20)
                .build();

        BetaMessage response = CLAUDE.beta().messages().create(params);

        String answer = response.content().stream()
                .flatMap(block -> block.text().stream())
                .map(textBlock -> textBlock.text())
                .findFirst()
                .orElse("回答を生成できませんでした。");

        List<Map<String, String>> sources = extractSources(response);

        return jsonResponse(200, Map.of("answer", answer, "sources", sources));
    }

    /**
     * The mcp() tool handler formats each retrieved chunk as
     * "### {title}\nSource: {url}\n\n{chunkText}\n\n---\n\n" (see mcp()
     * below). This is a private contract between that writer and this
     * reader, not part of the MCP spec - we dig sources back out of the
     * mcp_tool_result content blocks the connector attaches to the response.
     */
    private static List<Map<String, String>> extractSources(BetaMessage response) {
        Map<String, Map<String, String>> byUrl = new LinkedHashMap<>();
        for (var block : response.content()) {
            block.mcpToolResult().ifPresent(result ->
                    result.content().betaMcpToolResultBlock().ifPresent(textBlocks -> {
                        for (BetaTextBlock textBlock : textBlocks) {
                            Matcher m = SOURCE_PATTERN.matcher(textBlock.text());
                            while (m.find()) {
                                String title = m.group(1).trim();
                                String url = m.group(2).trim();
                                byUrl.putIfAbsent(url, Map.of("title", title, "url", url));
                            }
                        }
                    }));
        }
        return new ArrayList<>(byUrl.values());
    }

    // ---------------------------------------------------------------------
    // POST /mcp - MCP Streamable HTTP server, called only by Anthropic's
    // backend during the messages().create() call above. Stateless: every
    // request is a single self-contained JSON-RPC 2.0 object, answered with
    // a single JSON object (no SSE), which the spec allows for servers that
    // don't need to stream multiple messages per request.
    // ---------------------------------------------------------------------

    private APIGatewayV2HTTPResponse mcp(APIGatewayV2HTTPEvent event) throws Exception {
        String auth = headerIgnoreCase(event, "authorization");
        if (auth == null || !auth.equals("Bearer " + MCP_SHARED_SECRET)) {
            return jsonResponse(401, Map.of("error", "unauthorized"));
        }

        JsonNode body = MAPPER.readTree(event.getBody() == null ? "{}" : event.getBody());
        String method = body.path("method").asText("");
        JsonNode id = body.get("id");

        if ("notifications/initialized".equals(method)) {
            // Notification: no id, no response body expected.
            APIGatewayV2HTTPResponse response = new APIGatewayV2HTTPResponse();
            response.setStatusCode(202);
            response.setBody("");
            return response;
        }

        if ("initialize".equals(method)) {
            return jsonRpcResult(id, Map.of(
                    "protocolVersion", "2025-06-18",
                    "capabilities", Map.of("tools", Map.of()),
                    "serverInfo", Map.of("name", "blog-search", "version", "1.0.0")
            ));
        }

        if ("tools/list".equals(method)) {
            return jsonRpcResult(id, Map.of("tools", List.of(Map.of(
                    "name", "search_blog_posts",
                    "description",
                    "Search this blog's own posts for content relevant to a question. "
                            + "Call this before answering any question about the blog's content.",
                    "inputSchema", Map.of(
                            "type", "object",
                            "properties", Map.of("query", Map.of("type", "string")),
                            "required", List.of("query")
                    )
            ))));
        }

        if ("tools/call".equals(method)) {
            JsonNode params = body.path("params");
            if (!"search_blog_posts".equals(params.path("name").asText(""))) {
                return jsonRpcError(id, -32602, "unknown tool");
            }
            String query = params.path("arguments").path("query").asText("");
            String resultText = searchBlogPosts(query);
            return jsonRpcResult(id, Map.of(
                    "content", List.of(Map.of("type", "text", "text", resultText))
            ));
        }

        return jsonRpcError(id, -32601, "method not found: " + method);
    }

    private String searchBlogPosts(String query) throws Exception {
        IndexStore store = getIndexStore();
        VoyageClient voyage = new VoyageClient(VOYAGE_API_KEY);
        float[] queryEmbedding = voyage.embedQuery(query);
        List<Chunk> topChunks = store.topK(queryEmbedding, TOP_K);

        if (topChunks.isEmpty()) {
            return "このブログはまだ記事がありません。";
        }

        StringBuilder sb = new StringBuilder();
        for (Chunk c : topChunks) {
            sb.append("### ").append(c.title).append('\n')
                    .append("Source: ").append(c.url).append("\n\n")
                    .append(c.chunkText).append("\n\n---\n\n");
        }
        return sb.toString();
    }

    private static synchronized IndexStore getIndexStore() throws Exception {
        if (indexStore == null) {
            indexStore = IndexStore.load(S3, BUCKET_NAME, INDEX_KEY);
        }
        return indexStore;
    }

    private static String trimToNull(String s) {
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }

    private static String headerIgnoreCase(APIGatewayV2HTTPEvent event, String name) {
        if (event.getHeaders() == null) return null;
        for (Map.Entry<String, String> e : event.getHeaders().entrySet()) {
            if (e.getKey().equalsIgnoreCase(name)) return e.getValue();
        }
        return null;
    }

    private static APIGatewayV2HTTPResponse jsonRpcResult(JsonNode id, Object result) {
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("jsonrpc", "2.0");
        envelope.put("id", id == null ? null : idValue(id));
        envelope.put("result", result);
        return jsonResponse(200, envelope);
    }

    private static APIGatewayV2HTTPResponse jsonRpcError(JsonNode id, int code, String message) {
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("jsonrpc", "2.0");
        envelope.put("id", id == null ? null : idValue(id));
        envelope.put("error", Map.of("code", code, "message", message));
        return jsonResponse(200, envelope);
    }

    private static Object idValue(JsonNode id) {
        if (id.isNumber()) return id.numberValue();
        return id.asText();
    }

    private static APIGatewayV2HTTPResponse jsonResponse(int status, Object body) {
        try {
            APIGatewayV2HTTPResponse response = new APIGatewayV2HTTPResponse();
            response.setStatusCode(status);
            response.setHeaders(Map.of("Content-Type", "application/json; charset=utf-8"));
            response.setBody(MAPPER.writeValueAsString(body));
            return response;
        } catch (Exception e) {
            APIGatewayV2HTTPResponse response = new APIGatewayV2HTTPResponse();
            response.setStatusCode(500);
            response.setBody("{\"error\":\"serialization failure\"}");
            return response;
        }
    }
}
