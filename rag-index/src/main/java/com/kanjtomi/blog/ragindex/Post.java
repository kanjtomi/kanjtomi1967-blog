package com.kanjtomi.blog.ragindex;

public class Post {
    public final String slug;
    public final String title;
    public final String url;
    public final String body;
    public final boolean draft;

    public Post(String slug, String title, String url, String body, boolean draft) {
        this.slug = slug;
        this.title = title;
        this.url = url;
        this.body = body;
        this.draft = draft;
    }
}
