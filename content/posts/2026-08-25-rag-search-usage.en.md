---
title: "How to Use \"Ask AI\" - RAG Search on This Blog"
date: 2026-08-25
tags: ["blog", "aws", "rag", "ai"]
draft: false
---

The [search page](/en/search/) on this blog has a natural-language "Ask AI"
search powered by RAG (Retrieval-Augmented Generation), separate from the
regular keyword search. This post covers how to use it, and how it works
under the hood.

## How to use it

1. Open [`/search/`](/en/search/)
2. Above the existing keyword search (PaperMod's built-in fuse.js search),
   you'll see an "Ask AI" question box
3. Type a question in plain language

   Example: "Why does a non-root directory on CloudFront return a 403
   instead of serving index.html?"

4. Submitting runs a Cloudflare Turnstile bot check in the background;
   once it passes, the question is sent to the backend
5. After a few seconds you'll see an answer along with links to the
   source articles it was grounded in

If a question isn't covered by anything on this blog, the model is
instructed to say so honestly rather than answering from outside
knowledge. This is a search feature grounded **only** in this blog's own
content.

## How it works

### Indexing (build time)

`rag-index/` (a Java 17 / Maven CLI) reads every non-draft post under
`content/posts/`, splits each into chunks (by `##` heading, falling back
to ~1500-character sliding windows for long or heading-less sections),
embeds each chunk with Voyage AI's embeddings API (`voyage-3-lite`), and
uploads the resulting array of
`{id, slug, title, url, chunkText, embedding}` as `index.json` to a
dedicated S3 bucket (`www.kanjtomi1967.net-rag-index`).

This indexing step runs on every Jenkins deploy, between `Build` and
`Deploy` (the `Rebuild RAG Index` stage). So pushing a new or updated
post automatically shows up in the search index on the next deploy.

### Answering a question (runtime)

Questions go through API Gateway to a Lambda function (`blog-rag`, in
`lambda-rag/`, Java 17) on `POST /ask`.

1. Verify the Cloudflare Turnstile token server-side
2. On a cold start, download `index.json` from S3 and keep it in memory
   for the lifetime of the execution environment (warm invocations reuse it)
3. Embed the question via Voyage AI and rank every chunk by cosine
   similarity, brute-force (fine at this corpus size — no vector DB needed)
4. Take the top 4 chunks
5. Pass those chunks as grounding context to Claude (`claude-haiku-4-5`)
   and have it answer based on them
6. Return `{answer, sources: [{title, url}]}`

The API Gateway stage also has a conservative throttle (burst 5 / rate 2)
as a second line of defense against a scripted caller running up the
Claude bill.

## Summary

- Answers are grounded only in the blog's own posts, which keeps
  hallucination risk low and helps with "I remember reading this
  somewhere but can't find it"
- Push a post and the index updates automatically on the next deploy
- Turnstile + throttling keep both cost and abuse in check

If you can't quite recall the keyword for something you read here,
give "Ask AI" a try.
