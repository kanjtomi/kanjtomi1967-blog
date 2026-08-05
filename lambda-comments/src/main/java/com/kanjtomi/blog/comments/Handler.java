package com.kanjtomi.blog.comments;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Single Lambda handling all comment-related routes (routing by API Gateway HTTP API routeKey):
 *   POST /comments        - submit a new comment (status=pending), requires Turnstile token
 *   GET  /comments         - list approved comments for a given ?slug=
 *   GET  /admin/pending    - list all pending comments (requires x-api-key header)
 *   POST /admin/approve    - approve a comment: body {"slug": "...", "id": "..."} (requires x-api-key header)
 */
public class Handler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final S3Client S3 = S3Client.create();

    private static final String BUCKET_NAME = System.getenv("BUCKET_NAME");
    private static final String TURNSTILE_SECRET = System.getenv("TURNSTILE_SECRET");
    private static final String ADMIN_API_KEY = System.getenv("ADMIN_API_KEY");

    private static final int MAX_AUTHOR_LEN = 80;
    private static final int MAX_BODY_LEN = 3000;

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        String routeKey = event.getRouteKey();
        try {
            if ("POST /comments".equals(routeKey)) {
                return submitComment(event);
            } else if ("GET /comments".equals(routeKey)) {
                return listApprovedComments(event);
            } else if ("GET /admin/pending".equals(routeKey)) {
                return listPendingComments(event);
            } else if ("POST /admin/approve".equals(routeKey)) {
                return approveComment(event);
            }
            return jsonResponse(404, Map.of("error", "not found"));
        } catch (Exception e) {
            context.getLogger().log("Unhandled error: " + e);
            return jsonResponse(500, Map.of("error", "internal server error"));
        }
    }

    // --- POST /comments ---
    private APIGatewayV2HTTPResponse submitComment(APIGatewayV2HTTPEvent event) throws Exception {
        JsonNode body = MAPPER.readTree(event.getBody() == null ? "{}" : event.getBody());

        String slug = trimToNull(body.path("slug").asText(null));
        String author = trimToNull(body.path("author").asText(null));
        String text = trimToNull(body.path("body").asText(null));
        String turnstileToken = body.path("turnstileToken").asText(null);

        if (slug == null || author == null || text == null) {
            return jsonResponse(400, Map.of("error", "slug, author, and body are required"));
        }
        if (author.length() > MAX_AUTHOR_LEN || text.length() > MAX_BODY_LEN) {
            return jsonResponse(400, Map.of("error", "author or body too long"));
        }
        if (!slug.matches("[a-zA-Z0-9\\-_/]+")) {
            return jsonResponse(400, Map.of("error", "invalid slug"));
        }

        String remoteIp = event.getRequestContext() != null && event.getRequestContext().getHttp() != null
                ? event.getRequestContext().getHttp().getSourceIp()
                : null;

        if (!TurnstileVerifier.verify(TURNSTILE_SECRET, turnstileToken, remoteIp)) {
            return jsonResponse(400, Map.of("error", "captcha verification failed"));
        }

        String id = UUID.randomUUID().toString();
        String createdAt = Instant.now().toString();
        Comment comment = new Comment(id, slug, escapeHtml(author), escapeHtml(text), createdAt, "pending");

        putComment(comment);

        return jsonResponse(201, Map.of("id", id, "status", "pending"));
    }

    // --- GET /comments?slug=... ---
    private APIGatewayV2HTTPResponse listApprovedComments(APIGatewayV2HTTPEvent event) throws Exception {
        Map<String, String> qs = event.getQueryStringParameters();
        String slug = qs == null ? null : qs.get("slug");
        if (slug == null || slug.isBlank()) {
            return jsonResponse(400, Map.of("error", "slug query parameter is required"));
        }

        List<Comment> comments = listCommentsUnderPrefix("comments/" + slug + "/");
        List<Map<String, String>> publicComments = new ArrayList<>();
        for (Comment c : comments) {
            if ("approved".equals(c.status)) {
                publicComments.add(Map.of(
                        "id", c.id,
                        "author", c.author,
                        "body", c.body,
                        "createdAt", c.createdAt
                ));
            }
        }
        publicComments.sort(Comparator.comparing(m -> m.get("createdAt")));

        return jsonResponse(200, publicComments);
    }

    // --- GET /admin/pending ---
    private APIGatewayV2HTTPResponse listPendingComments(APIGatewayV2HTTPEvent event) throws Exception {
        if (!isAuthorizedAdmin(event)) {
            return jsonResponse(403, Map.of("error", "forbidden"));
        }

        List<Comment> all = listCommentsUnderPrefix("comments/");
        List<Comment> pending = all.stream().filter(c -> "pending".equals(c.status)).toList();
        return jsonResponse(200, pending);
    }

    // --- POST /admin/approve  { "slug": "...", "id": "..." } ---
    private APIGatewayV2HTTPResponse approveComment(APIGatewayV2HTTPEvent event) throws Exception {
        if (!isAuthorizedAdmin(event)) {
            return jsonResponse(403, Map.of("error", "forbidden"));
        }

        JsonNode body = MAPPER.readTree(event.getBody() == null ? "{}" : event.getBody());
        String slug = trimToNull(body.path("slug").asText(null));
        String id = trimToNull(body.path("id").asText(null));
        if (slug == null || id == null) {
            return jsonResponse(400, Map.of("error", "slug and id are required"));
        }

        String key = "comments/" + slug + "/" + id + ".json";
        Comment comment;
        try {
            comment = getComment(key);
        } catch (NoSuchKeyException e) {
            return jsonResponse(404, Map.of("error", "comment not found"));
        }

        comment.status = "approved";
        putComment(comment);

        return jsonResponse(200, Map.of("id", id, "status", "approved"));
    }

    // --- S3 helpers ---

    private void putComment(Comment comment) throws Exception {
        String key = "comments/" + comment.slug + "/" + comment.id + ".json";
        byte[] payload = MAPPER.writeValueAsBytes(comment);
        S3.putObject(
                PutObjectRequest.builder()
                        .bucket(BUCKET_NAME)
                        .key(key)
                        .contentType("application/json")
                        .build(),
                RequestBody.fromBytes(payload)
        );
    }

    private Comment getComment(String key) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        S3.getObject(GetObjectRequest.builder().bucket(BUCKET_NAME).key(key).build())
                .transferTo(out);
        return MAPPER.readValue(out.toByteArray(), Comment.class);
    }

    private List<Comment> listCommentsUnderPrefix(String prefix) throws Exception {
        List<Comment> results = new ArrayList<>();
        ListObjectsV2Request request = ListObjectsV2Request.builder()
                .bucket(BUCKET_NAME)
                .prefix(prefix)
                .build();

        ListObjectsV2Response response;
        do {
            response = S3.listObjectsV2(request);
            for (S3Object obj : response.contents()) {
                if (!obj.key().endsWith(".json")) continue;
                try {
                    results.add(getComment(obj.key()));
                } catch (Exception ignored) {
                    // skip unreadable/corrupt objects rather than failing the whole request
                }
            }
            request = request.toBuilder().continuationToken(response.nextContinuationToken()).build();
        } while (Boolean.TRUE.equals(response.isTruncated()));

        return results;
    }

    // --- misc helpers ---

    private boolean isAuthorizedAdmin(APIGatewayV2HTTPEvent event) {
        Map<String, String> headers = event.getHeaders();
        if (headers == null || ADMIN_API_KEY == null) return false;
        String provided = headers.getOrDefault("x-api-key", headers.get("X-Api-Key"));
        return ADMIN_API_KEY.equals(provided);
    }

    private static String trimToNull(String s) {
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }

    private static String escapeHtml(String s) {
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&#39;");
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
