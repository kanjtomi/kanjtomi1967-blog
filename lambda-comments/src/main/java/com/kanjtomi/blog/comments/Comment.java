package com.kanjtomi.blog.comments;

import com.fasterxml.jackson.annotation.JsonInclude;

@JsonInclude(JsonInclude.Include.NON_NULL)
public class Comment {
    public String id;
    public String slug;
    public String author;
    public String body;
    public String createdAt;
    public String status; // "pending" | "approved"

    public Comment() {
    }

    public Comment(String id, String slug, String author, String body, String createdAt, String status) {
        this.id = id;
        this.slug = slug;
        this.author = author;
        this.body = body;
        this.createdAt = createdAt;
        this.status = status;
    }
}
