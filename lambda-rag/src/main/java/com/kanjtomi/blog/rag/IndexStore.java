package com.kanjtomi.blog.rag;

import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * Loads the embeddings index built by rag-index from S3 and holds it in
 * memory for the lifetime of the Lambda execution environment (loaded once
 * on cold start, reused across warm invocations). Brute-force cosine
 * similarity is fine at this corpus size — no vector DB needed.
 */
public class IndexStore {

    private final List<Chunk> chunks;

    private IndexStore(List<Chunk> chunks) {
        this.chunks = chunks;
    }

    public static IndexStore load(S3Client s3, String bucket, String key) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        s3.getObject(GetObjectRequest.builder().bucket(bucket).key(key).build()).transferTo(out);
        ObjectMapper mapper = new ObjectMapper();
        Chunk[] loaded = mapper.readValue(out.toByteArray(), Chunk[].class);
        return new IndexStore(List.of(loaded));
    }

    public List<Chunk> topK(float[] queryEmbedding, int k) {
        List<Chunk> ranked = new ArrayList<>(chunks);
        ranked.sort(Comparator.comparingDouble((Chunk c) -> cosineSimilarity(queryEmbedding, c.embedding)).reversed());
        return ranked.subList(0, Math.min(k, ranked.size()));
    }

    private static double cosineSimilarity(float[] a, float[] b) {
        double dot = 0, normA = 0, normB = 0;
        for (int i = 0; i < a.length; i++) {
            dot += a[i] * b[i];
            normA += a[i] * a[i];
            normB += b[i] * b[i];
        }
        if (normA == 0 || normB == 0) return 0;
        return dot / (Math.sqrt(normA) * Math.sqrt(normB));
    }
}
