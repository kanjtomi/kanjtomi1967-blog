package com.kanjtomi.blog.rag;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.anthropic.client.AnthropicClient;
import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.anthropic.models.messages.Message;
import com.anthropic.models.messages.MessageCreateParams;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.services.s3.S3Client;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Single Lambda behind the RAG "ask this blog" search:
 *   POST /ask  { "question": "...", "turnstileToken": "..." }
 *     -> { "answer": "...", "sources": [{"title": "...", "url": "..."}] }
 */
public class Handler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final S3Client S3 = S3Client.create();
    private static final AnthropicClient CLAUDE = AnthropicOkHttpClient.fromEnv();

    private static final String BUCKET_NAME = System.getenv("BUCKET_NAME");
    private static final String INDEX_KEY = System.getenv().getOrDefault("INDEX_KEY", "index.json");
    private static final String TURNSTILE_SECRET = System.getenv("TURNSTILE_SECRET");
    private static final String VOYAGE_API_KEY = System.getenv("VOYAGE_API_KEY");

    private static final int MAX_QUESTION_LEN = 300;
    private static final int TOP_K = 4;

    private static final String SYSTEM_PROMPT = """
            You are a helpful assistant answering questions about a personal technical blog \
            (topics: AWS, Hugo, Jenkins, AI, infrastructure). You will be given excerpts from \
            the blog's posts. Answer the user's question using only information found in those \
            excerpts. If the excerpts do not contain enough information to answer, say plainly \
            that the blog doesn't cover this topic yet - do not use outside knowledge to fill \
            the gap. Respond in the same language as the question. Keep the answer concise.""";

    // Loaded once per Lambda execution environment (cold start), reused across warm invocations.
    private static volatile IndexStore indexStore;

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        String routeKey = event.getRouteKey();
        try {
            if ("POST /ask".equals(routeKey)) {
                return ask(event);
            }
            return jsonResponse(404, Map.of("error", "not found"));
        } catch (Exception e) {
            context.getLogger().log("Unhandled error: " + e);
            return jsonResponse(500, Map.of("error", "internal server error"));
        }
    }

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

        IndexStore store = getIndexStore();

        VoyageClient voyage = new VoyageClient(VOYAGE_API_KEY);
        float[] queryEmbedding = voyage.embedQuery(question);
        List<Chunk> topChunks = store.topK(queryEmbedding, TOP_K);

        if (topChunks.isEmpty()) {
            return jsonResponse(200, Map.of(
                    "answer", "このブログはまだ記事がありません。",
                    "sources", List.of()
            ));
        }

        String answer = generateAnswer(question, topChunks);
        List<Map<String, String>> sources = dedupSources(topChunks);

        return jsonResponse(200, Map.of("answer", answer, "sources", sources));
    }

    private String generateAnswer(String question, List<Chunk> chunks) {
        StringBuilder context = new StringBuilder();
        for (Chunk c : chunks) {
            context.append("### ").append(c.title).append('\n').append(c.chunkText).append("\n\n");
        }

        String userMessage = "Blog excerpts:\n\n" + context + "\nQuestion: " + question;

        MessageCreateParams params = MessageCreateParams.builder()
                .model("claude-haiku-4-5")
                .maxTokens(1024L)
                .system(SYSTEM_PROMPT)
                .addUserMessage(userMessage)
                .build();

        Message response = CLAUDE.messages().create(params);
        return response.content().stream()
                .flatMap(block -> block.text().stream())
                .map(textBlock -> textBlock.text())
                .findFirst()
                .orElse("回答を生成できませんでした。");
    }

    private static List<Map<String, String>> dedupSources(List<Chunk> chunks) {
        Map<String, Map<String, String>> byUrl = new LinkedHashMap<>();
        for (Chunk c : chunks) {
            byUrl.putIfAbsent(c.url, Map.of("title", c.title, "url", c.url));
        }
        return new ArrayList<>(byUrl.values());
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
