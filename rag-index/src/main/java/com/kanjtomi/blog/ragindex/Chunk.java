package com.kanjtomi.blog.ragindex;

import com.fasterxml.jackson.annotation.JsonInclude;

@JsonInclude(JsonInclude.Include.NON_NULL)
public class Chunk {
    public String id;
    public String slug;
    public String title;
    public String url;
    public String chunkText;
    public float[] embedding;

    public Chunk() {
    }

    public Chunk(String id, String slug, String title, String url, String chunkText, float[] embedding) {
        this.id = id;
        this.slug = slug;
        this.title = title;
        this.url = url;
        this.chunkText = chunkText;
        this.embedding = embedding;
    }
}
