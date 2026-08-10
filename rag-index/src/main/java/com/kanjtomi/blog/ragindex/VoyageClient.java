package com.kanjtomi.blog.ragindex;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

/**
 * Minimal client for the Voyage AI embeddings endpoint.
 * Docs: https://docs.voyageai.com/reference/embeddings-api
 */
public class VoyageClient {

    private static final String EMBED_URL = "https://api.voyageai.com/v1/embeddings";
    private static final String MODEL = "voyage-3-lite";
    private static final int BATCH_SIZE = 32;

    private final String apiKey;
    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();
    private final ObjectMapper mapper = new ObjectMapper();

    public VoyageClient(String apiKey) {
        this.apiKey = apiKey;
    }

    /** inputType is "document" when indexing, "query" when embedding a search question. */
    public List<float[]> embed(List<String> texts, String inputType) throws Exception {
        List<float[]> results = new ArrayList<>();
        for (int start = 0; start < texts.size(); start += BATCH_SIZE) {
            List<String> batch = texts.subList(start, Math.min(start + BATCH_SIZE, texts.size()));
            results.addAll(embedBatch(batch, inputType));
        }
        return results;
    }

    private List<float[]> embedBatch(List<String> batch, String inputType) throws Exception {
        var requestBody = mapper.createObjectNode();
        requestBody.put("model", MODEL);
        requestBody.put("input_type", inputType);
        var inputArray = requestBody.putArray("input");
        batch.forEach(inputArray::add);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(EMBED_URL))
                .header("Authorization", "Bearer " + apiKey)
                .header("Content-Type", "application/json")
                .timeout(Duration.ofSeconds(30))
                .POST(HttpRequest.BodyPublishers.ofString(
                        mapper.writeValueAsString(requestBody), StandardCharsets.UTF_8))
                .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() != 200) {
            throw new RuntimeException("Voyage AI embeddings request failed: HTTP "
                    + response.statusCode() + " - " + response.body());
        }

        JsonNode root = mapper.readTree(response.body());
        JsonNode data = root.path("data");
        float[][] ordered = new float[batch.size()][];
        for (JsonNode item : data) {
            int index = item.path("index").asInt();
            JsonNode embeddingNode = item.path("embedding");
            float[] vector = new float[embeddingNode.size()];
            for (int i = 0; i < vector.length; i++) {
                vector[i] = (float) embeddingNode.get(i).asDouble();
            }
            ordered[index] = vector;
        }

        List<float[]> results = new ArrayList<>();
        for (float[] vector : ordered) {
            results.add(vector);
        }
        return results;
    }
}
