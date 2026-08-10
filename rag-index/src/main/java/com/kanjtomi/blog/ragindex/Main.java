package com.kanjtomi.blog.ragindex;

import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.stream.Stream;

/**
 * Build-time indexer for the "ask this blog" RAG search feature.
 *
 * Reads every non-draft post under CONTENT_DIR, chunks it, embeds each chunk
 * via Voyage AI, and uploads the resulting index as a single JSON object to
 * S3 for lambda-rag to load at cold start.
 *
 * Env vars:
 *   VOYAGE_API_KEY   (required) Voyage AI API key
 *   RAG_BUCKET_NAME  (required) S3 bucket to upload index.json to
 *   CONTENT_DIR      (optional, default "content/posts")
 *   INDEX_KEY        (optional, default "index.json")
 */
public class Main {

    public static void main(String[] args) throws Exception {
        String voyageApiKey = requireEnv("VOYAGE_API_KEY");
        String bucketName = requireEnv("RAG_BUCKET_NAME");
        String contentDir = System.getenv().getOrDefault("CONTENT_DIR", "content/posts");
        String indexKey = System.getenv().getOrDefault("INDEX_KEY", "index.json");

        List<Post> posts = loadPosts(Path.of(contentDir));
        System.out.println("Loaded " + posts.size() + " non-draft post(s) from " + contentDir);

        // Flatten (post, chunkText) pairs so all chunks can be embedded in shared batches.
        List<Post> chunkOwner = new ArrayList<>();
        List<String> chunkTexts = new ArrayList<>();
        for (Post post : posts) {
            for (String chunkText : Chunker.chunk(post.body)) {
                chunkOwner.add(post);
                chunkTexts.add(chunkText);
            }
        }
        System.out.println("Split into " + chunkTexts.size() + " chunk(s)");

        VoyageClient voyage = new VoyageClient(voyageApiKey);
        List<float[]> embeddings = voyage.embed(chunkTexts, "document");

        List<Chunk> chunks = new ArrayList<>();
        for (int i = 0; i < chunkTexts.size(); i++) {
            Post owner = chunkOwner.get(i);
            chunks.add(new Chunk(
                    UUID.randomUUID().toString(),
                    owner.slug,
                    owner.title,
                    owner.url,
                    chunkTexts.get(i),
                    embeddings.get(i)
            ));
        }

        ObjectMapper mapper = new ObjectMapper();
        byte[] payload = mapper.writeValueAsBytes(chunks);
        System.out.println("Index size: " + payload.length + " bytes");

        try (S3Client s3 = S3Client.create()) {
            s3.putObject(
                    PutObjectRequest.builder()
                            .bucket(bucketName)
                            .key(indexKey)
                            .contentType("application/json")
                            .build(),
                    RequestBody.fromBytes(payload)
            );
        }
        System.out.println("Uploaded to s3://" + bucketName + "/" + indexKey);
    }

    private static List<Post> loadPosts(Path contentDir) throws Exception {
        List<Post> posts = new ArrayList<>();
        try (Stream<Path> files = Files.list(contentDir)) {
            for (Path file : files.filter(p -> p.toString().endsWith(".md")).toList()) {
                Post post = PostParser.parse(file);
                if (!post.draft) {
                    posts.add(post);
                }
            }
        }
        return posts;
    }

    private static String requireEnv(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("Missing required environment variable: " + name);
        }
        return value;
    }
}
