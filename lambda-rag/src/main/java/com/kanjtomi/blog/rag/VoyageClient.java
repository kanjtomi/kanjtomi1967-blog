package com.kanjtomi.blog.rag;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

/**
 * Minimal client for the Voyage AI embeddings endpoint — embeds a single
 * search query at request time. The index itself is built offline by
 * rag-index using the same model (voyage-3-lite), so vectors are comparable.
 * Docs: https://docs.voyageai.com/reference/embeddings-api
 */
public class VoyageClient {

    private static final String EMBED_URL = "https://api.voyageai.com/v1/embeddings";
    private static final String MODEL = "voyage-3-lite";

    private final String apiKey;
    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();
    private final ObjectMapper mapper = new ObjectMapper();

    public VoyageClient(String apiKey) {
        this.apiKey = apiKey;
    }

    public float[] embedQuery(String text) throws Exception {
        var requestBody = mapper.createObjectNode();
        requestBody.put("model", MODEL);
        requestBody.put("input_type", "query");
        requestBody.putArray("input").add(text);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(EMBED_URL))
                .header("Authorization", "Bearer " + apiKey)
                .header("Content-Type", "application/json")
                .timeout(Duration.ofSeconds(10))
                .POST(HttpRequest.BodyPublishers.ofString(
                        mapper.writeValueAsString(requestBody), StandardCharsets.UTF_8))
                .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() != 200) {
            throw new RuntimeException("Voyage AI embeddings request failed: HTTP "
                    + response.statusCode() + " - " + response.body());
        }

        JsonNode embeddingNode = mapper.readTree(response.body()).path("data").get(0).path("embedding");
        float[] vector = new float[embeddingNode.size()];
        for (int i = 0; i < vector.length; i++) {
            vector[i] = (float) embeddingNode.get(i).asDouble();
        }
        return vector;
    }
}
