package com.kanjtomi.blog.rag;

import com.fasterxml.jackson.annotation.JsonInclude;

/** Mirrors the record shape written by rag-index/Chunk.java into index.json. */
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
}
