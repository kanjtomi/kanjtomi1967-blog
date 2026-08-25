import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";

export interface IndexEntry {
  id: string;
  slug: string;
  title: string;
  url: string;
  chunkText: string;
  embedding: number[];
}

export interface SearchResult {
  title: string;
  url: string;
  excerpt: string;
  score: number;
}

const s3 = new S3Client({});

// Cached across warm Lambda invocations within the same execution environment,
// same pattern as blog-rag (lambda-rag/).
let cachedIndex: IndexEntry[] | null = null;

async function loadIndex(bucket: string, key: string): Promise<IndexEntry[]> {
  if (cachedIndex) return cachedIndex;

  const res = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const body = await res.Body?.transformToString();
  if (!body) throw new Error(`index.json empty or missing at s3://${bucket}/${key}`);

  cachedIndex = JSON.parse(body) as IndexEntry[];
  return cachedIndex;
}

async function embedQuery(query: string, voyageApiKey: string): Promise<number[]> {
  const res = await fetch("https://api.voyageai.com/v1/embeddings", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${voyageApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      input: [query],
      model: "voyage-3-lite",
      input_type: "query",
    }),
  });

  if (!res.ok) {
    throw new Error(`Voyage AI embedding request failed: ${res.status} ${await res.text()}`);
  }

  const data = (await res.json()) as { data: { embedding: number[] }[] };
  return data.data[0].embedding;
}

function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}

export async function searchBlogPosts(
  query: string,
  topK: number,
  env: { bucket: string; key: string; voyageApiKey: string }
): Promise<SearchResult[]> {
  const [index, queryEmbedding] = await Promise.all([
    loadIndex(env.bucket, env.key),
    embedQuery(query, env.voyageApiKey),
  ]);

  const ranked = index
    .map((entry) => ({
      entry,
      score: cosineSimilarity(queryEmbedding, entry.embedding),
    }))
    .sort((a, b) => b.score - a.score)
    .slice(0, topK);

  return ranked.map(({ entry, score }) => ({
    title: entry.title,
    url: entry.url,
    excerpt: entry.chunkText,
    score: Math.round(score * 1000) / 1000,
  }));
}
