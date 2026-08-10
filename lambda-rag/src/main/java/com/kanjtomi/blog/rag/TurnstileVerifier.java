package com.kanjtomi.blog.rag;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

/**
 * Verifies a Cloudflare Turnstile token server-side via the siteverify endpoint.
 * Docs: https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
 */
public class TurnstileVerifier {

    private static final String VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
    private static final HttpClient HTTP_CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static boolean verify(String secret, String token, String remoteIp) {
        if (token == null || token.isBlank()) {
            return false;
        }
        try {
            StringBuilder form = new StringBuilder();
            form.append("secret=").append(URLEncoder.encode(secret, StandardCharsets.UTF_8));
            form.append("&response=").append(URLEncoder.encode(token, StandardCharsets.UTF_8));
            if (remoteIp != null && !remoteIp.isBlank()) {
                form.append("&remoteip=").append(URLEncoder.encode(remoteIp, StandardCharsets.UTF_8));
            }

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(VERIFY_URL))
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .POST(HttpRequest.BodyPublishers.ofString(form.toString()))
                    .timeout(Duration.ofSeconds(5))
                    .build();

            HttpResponse<String> response = HTTP_CLIENT.send(request, HttpResponse.BodyHandlers.ofString());
            JsonNode json = MAPPER.readTree(response.body());
            return json.path("success").asBoolean(false);
        } catch (Exception e) {
            // Fail closed: any verification error is treated as a failed check.
            return false;
        }
    }
}
