package com.kanjtomi.blog.photoupload;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.PresignedPutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.model.PutObjectPresignRequest;

import java.time.Duration;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.util.Map;
import java.util.UUID;

/**
 * Single-route Lambda that issues short-lived presigned S3 PUT URLs so the
 * photo-upload page can upload directly to S3 (bypassing API Gateway/Lambda
 * payload-size limits):
 *   POST /presign  { "contentType": "image/jpeg" }  (requires x-api-key header)
 */
public class Handler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final S3Presigner PRESIGNER = S3Presigner.create();

    private static final String BUCKET_NAME = System.getenv("BUCKET_NAME");
    private static final String ADMIN_API_KEY = System.getenv("ADMIN_API_KEY");
    private static final String SITE_SUBDOMAIN = System.getenv("SITE_SUBDOMAIN");

    // Key derived from the (validated) content-type, never from client-supplied
    // filenames — sidesteps path traversal / filename sanitization entirely.
    private static final Map<String, String> ALLOWED_CONTENT_TYPES = Map.of(
            "image/jpeg", "jpg",
            "image/png", "png",
            "image/heic", "heic",
            "image/heif", "heif",
            "image/webp", "webp",
            "image/gif", "gif"
    );

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        try {
            if (!"POST /presign".equals(event.getRouteKey())) {
                return jsonResponse(404, Map.of("error", "not found"));
            }
            return presign(event);
        } catch (Exception e) {
            context.getLogger().log("Unhandled error: " + e);
            return jsonResponse(500, Map.of("error", "internal server error"));
        }
    }

    private APIGatewayV2HTTPResponse presign(APIGatewayV2HTTPEvent event) throws Exception {
        if (!isAuthorized(event)) {
            return jsonResponse(403, Map.of("error", "forbidden"));
        }

        JsonNode body = MAPPER.readTree(event.getBody() == null ? "{}" : event.getBody());
        String contentType = body.path("contentType").asText(null);
        String ext = contentType == null ? null : ALLOWED_CONTENT_TYPES.get(contentType.toLowerCase());
        if (ext == null) {
            return jsonResponse(400, Map.of("error", "unsupported or missing contentType"));
        }

        String year = String.valueOf(ZonedDateTime.now(ZoneOffset.UTC).getYear());
        String key = "photos/" + year + "/" + UUID.randomUUID() + "." + ext;

        PutObjectRequest putRequest = PutObjectRequest.builder()
                .bucket(BUCKET_NAME)
                .key(key)
                .contentType(contentType)
                .build();

        PutObjectPresignRequest presignRequest = PutObjectPresignRequest.builder()
                .signatureDuration(Duration.ofMinutes(5))
                .putObjectRequest(putRequest)
                .build();

        PresignedPutObjectRequest presigned = PRESIGNER.presignPutObject(presignRequest);
        String publicUrl = "https://" + SITE_SUBDOMAIN + "/" + key;

        return jsonResponse(200, Map.of(
                "uploadUrl", presigned.url().toString(),
                "publicUrl", publicUrl
        ));
    }

    private boolean isAuthorized(APIGatewayV2HTTPEvent event) {
        Map<String, String> headers = event.getHeaders();
        if (headers == null || ADMIN_API_KEY == null) return false;
        String provided = headers.getOrDefault("x-api-key", headers.get("X-Api-Key"));
        return ADMIN_API_KEY.equals(provided);
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
