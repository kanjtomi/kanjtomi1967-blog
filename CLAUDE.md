# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## Project Overview

A personal, single-author technical blog (Qiita-style: article list + tag browsing +
code syntax highlighting), built as a **static site** and hosted on AWS at minimal cost.

- **Site domain**: `www.kanjtomi1967.net`

No backend, no database, no authentication — content is Markdown files built into
static HTML and served via S3 + CloudFront.

## Tech Stack

- **Site generator**: Hugo (static site generator)
- **Content**: Markdown files with front-matter (title, date, tags)
- **Hosting**: AWS S3 (static website bucket)
- **CDN / TLS**: AWS CloudFront + ACM (cert must be issued in `us-east-1`)
- **DNS**: AWS Route 53 (existing domain)
- **Source control**: GitHub
- **CI/CD**: Jenkins, self-hosted locally on Windows → build → `aws s3 sync` → CloudFront invalidation

## Directory Structure

```
.
├── content/
│   └── posts/
│       ├── 2026-08-02-my-first-post.md
│       └── ...
├── layouts/          # Hugo theme overrides (if any)
├── static/           # images, favicon, etc.
├── themes/           # Hugo theme (submodule or vendored)
├── config.toml       # Hugo site config
└── Jenkinsfile       # CI/CD pipeline definition
```

## Common Commands

```bash
# Local dev server with live reload
hugo server -D

# Build production site (outputs to ./public)
hugo --minify

# New post
hugo new posts/my-new-post.md
```

## Deployment

Source is hosted on **GitHub**. **Jenkins runs locally on Windows** and builds/deploys
the site via the pipeline defined in `Jenkinsfile`:

1. Checkout source from GitHub
2. `hugo --minify` builds the site into `.\public`
3. `aws s3 sync .\public s3://<BUCKET_NAME> --delete`
4. `aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths "/*"`

**Windows-specific notes:**

- Use `bat` steps (not `sh`) in the Jenkinsfile, since the Jenkins agent runs on Windows
- **Hugo** and **AWS CLI** must be installed on the Windows machine and available on `PATH`
  for the Jenkins service/agent (check with `hugo version` and `aws --version` from the
  same context Jenkins runs as, e.g. as a Windows service account)
- **Trigger**: since Jenkins is local (not internet-reachable), GitHub cannot send a
  webhook to it directly. Use one of:
  - **Poll SCM** (`H/5 * * * *` — Jenkins checks GitHub every 5 min for new commits), simplest, no extra setup
  - Expose Jenkins via a tunnel (e.g. ngrok, Cloudflare Tunnel) and configure a GitHub webhook — more real-time, more setup
  - Manual "Build Now" trigger
- AWS credentials: store as Jenkins Credentials (Manage Jenkins → Credentials), do not hardcode.
  Use the [CloudBees AWS Credentials plugin](https://plugins.jenkins.io/aws-credentials/) or
  set environment variables via `withCredentials` and call the AWS CLI directly (simpler than
  `pipeline-aws` plugin on Windows, since some of its steps assume a Unix shell)

Example `Jenkinsfile` (declarative pipeline, Windows agent):

```groovy
pipeline {
    agent any

    triggers {
        pollSCM('H/5 * * * *')
    }

    environment {
        BUCKET_NAME = '<BUCKET_NAME>'
        DIST_ID     = '<DIST_ID>'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build') {
            steps {
                bat 'hugo --minify'
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                   credentialsId: 'aws-blog-deploy-creds']]) {
                    bat "aws s3 sync .\\public s3://%BUCKET_NAME% --delete"
                    bat "aws cloudfront create-invalidation --distribution-id %DIST_ID% --paths \"/*\""
                }
            }
        }
    }
}
```

Manual deploy (if needed, from Windows PowerShell/cmd):

```bat
hugo --minify
aws s3 sync .\public s3://<BUCKET_NAME> --delete
aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths "/*"
```

## AWS Infrastructure Notes

- **S3 bucket**: static website hosting enabled, private (accessed only via CloudFront OAC, not public)
- **CloudFront**: origin = S3 bucket via Origin Access Control; custom domain + ACM cert attached.
  A CloudFront Function (`hugo-directory-index-rewrite`) on `viewer-request`
  rewrites directory-style URIs (e.g. `/posts/test-post/`) to their `index.html`
  — required because S3-via-OAC only auto-resolves `index.html` for the exact
  root `/`, not for subdirectories, which otherwise return 403 AccessDenied
  instead of serving the page.
- **ACM**: certificate must be requested in `us-east-1` region regardless of where the bucket lives
- **Route 53**: hosted zone for `kanjtomi1967.net`; alias A/AAAA record for
  `www.kanjtomi1967.net` pointing to the CloudFront distribution (main site).
  A separate alias A/AAAA record for the apex `kanjtomi1967.net` points to a
  second, small CloudFront distribution used purely for the apex → www redirect
  (see below).
- **Apex redirect** (`kanjtomi1967.net` → `www.kanjtomi1967.net`):
  - A second CloudFront distribution serves the apex domain
  - A **CloudFront Function** (runs at the edge, on `viewer-request`) intercepts
    every request and returns a 301 redirect to `https://www.kanjtomi1967.net<uri>`
    — no origin fetch ever happens, so **no public S3 bucket is required**
  - This avoids conflicts with account-level S3 Block Public Access (the
    original design used a public S3 website-redirect bucket, which failed
    due to account-level Block Public Access restrictions — switched to the
    CloudFront Function approach, which AWS recommends for apex redirects anyway)
- **ACM cert**: main cert for `www.kanjtomi1967.net` (site) requested in
  `us-east-1`; can be the same cert (with both `www.kanjtomi1967.net` and
  `kanjtomi1967.net` as SANs) reused across both CloudFront distributions,
  or two separate certs — either works
- **Estimated cost**: ~$1–3/month total (Route 53 hosted zone fee + a second
  small CloudFront distribution for the redirect adds negligible cost since
  it serves almost no traffic; CloudFront/S3 usage for the main site is
  within or near free tier for personal traffic)

## Live Infrastructure Reference

All infrastructure below is deployed and working (region: `ap-northeast-1`
except ACM which is `us-east-1`):

- Site S3 bucket: `www.kanjtomi1967.net`
- Comments S3 bucket: `www.kanjtomi1967.net-comments`
- Site CloudFront distribution ID: `E1E2XGWP46PS1T`
- Apex-redirect CloudFront distribution ID: `E2C6IE1U5L07Z1`
- Comments API Gateway endpoint: `https://0fr1eq5b4j.execute-api.ap-northeast-1.amazonaws.com`
- Lambda function name: `blog-comments`
- RAG index S3 bucket: `www.kanjtomi1967.net-rag-index`
- RAG Lambda function name: `blog-rag`
- RAG API Gateway endpoint: `https://xaq4ljfx63.execute-api.ap-northeast-1.amazonaws.com`
- Route 53 hosted zone: `kanjtomi1967.net` (pre-existing, referenced via data source, not managed by this Terraform)
- Jenkins job name: `BlogDeploy`, running on a local Windows Jenkins instance, triggered by Poll SCM (`H/5 * * * *`)
- GitHub repo: `https://github.com/kanjtomi/kanjtomi1967-blog` (public)

## Conventions

- Post filenames: `YYYY-MM-DD-slug.md`
- Front-matter fields: `title`, `date`, `tags`, `draft`
- Tags are used to generate `/tags/<tag>/` index pages automatically via Hugo taxonomy

## Comment System (Lambda + S3)

Self-hosted comments (not Giscus/Disqus), moderated (approval required before
publishing), protected by Cloudflare Turnstile.

- **Storage**: dedicated private S3 bucket (`www.kanjtomi1967.net-comments`),
  one JSON object per comment at `comments/{slug}/{id}.json` with a `status`
  field (`pending` | `approved`)
- **Backend**: single Java 17 Lambda (`lambda-comments/`), routed internally
  by API Gateway HTTP API routeKey:
  - `POST /comments` — public, submits a comment (always starts as `pending`),
    requires a valid Cloudflare Turnstile token (verified server-side)
  - `GET /comments?slug=...` — public, returns only `approved` comments for a slug
  - `GET /admin/pending` — requires `x-api-key` header, lists all pending comments
  - `POST /admin/approve` — requires `x-api-key` header, body `{slug, id}`, flips status to `approved`
- **Frontend**: `layouts/_partials/comments.html` (note: `_partials`, not `partials` —
  Hugo 0.146+ moved the partials lookup directory) overrides PaperMod's built-in
  comments hook (enabled via `params.comments = true` in `config.toml`) —
  no `single.html` override needed, PaperMod calls this partial automatically
  on pages where comments are enabled
- **Moderation workflow**: no admin UI — approve via `curl`/PowerShell using
  the `x-api-key`, see `scripts/comments-admin.md`
- **Cost**: Lambda + API Gateway HTTP API usage for a personal blog stays
  within or very near free tier; realistically a few cents to ~$1/month even
  after free tier
- **Config values (already set, live)**:
  `params.commentsApiBase = "https://0fr1eq5b4j.execute-api.ap-northeast-1.amazonaws.com"`,
  `params.turnstileSiteKey = "0x4AAAAAAEG_N4t-dvN2MMCh"` (both public values —
  safe to be in the public repo; the Turnstile *secret* key and `admin_api_key`
  stay in `terraform.tfvars`, which is gitignored and confirmed never committed)
- **Build**: `lambda-comments/` is a Maven project producing a shaded fat JAR
  (`mvn package` → `target/comments-lambda.jar`), which Terraform's
  `aws_lambda_function.comments` deploys directly. This build step must run
  before `terraform apply` picks up changes to the Lambda code.

## RAG Search (Voyage + Lambda + S3)

"AI に聞く" — a RAG-based natural-language search over the blog's own posts, shown
on the search page (`/search/`) above the existing PaperMod/fuse.js keyword search.
Answers are grounded only in the blog's content; the model is told to say so plainly
when a question isn't covered rather than answering from outside knowledge.

- **Indexing (build-time, not a Lambda)**: `rag-index/`, a Java 17/Maven CLI. Reads
  every non-draft post under `content/posts/`, splits each into chunks (by `##`
  heading, falling back to ~1500-char sliding windows for long/heading-less
  sections), embeds each chunk via the **Voyage AI** embeddings API
  (`voyage-3-lite`), and uploads a single `index.json` (array of
  `{id, slug, title, url, chunkText, embedding}`) to a dedicated private S3 bucket
  (`www.kanjtomi1967.net-rag-index`). Runs on every Jenkins deploy (`Rebuild RAG
  Index` stage, between `Build` and `Deploy`), so the index always reflects the
  latest posts.
- **Query backend**: `lambda-rag/`, a Java 17 Lambda (`blog-rag`) behind its own
  API Gateway HTTP API, single route `POST /ask`:
  - Verifies the Cloudflare Turnstile token (reuses `params.turnstileSiteKey`;
    same verification pattern as the comment system, duplicated rather than
    shared between the two Lambdas)
  - Downloads `index.json` from S3 once per execution environment (cold start),
    holds it in memory across warm invocations
  - Embeds the incoming question via Voyage AI, ranks all chunks by cosine
    similarity in memory (brute-force — fine at this corpus size, no vector DB),
    takes the top 4
  - Calls Claude (`com.anthropic:anthropic-java`, model `claude-haiku-4-5`) with
    the retrieved chunks as grounding context
  - Returns `{answer, sources: [{title, url}]}`
  - The API Gateway stage also has a conservative throttle (burst 5 / rate 2) as
    a second line of defense against a scripted caller running up the Claude bill
- **Frontend**: `layouts/search.html` (theme override of PaperMod's default
  search page) — vanilla JS, same style as `layouts/_partials/comments.html`.
- **Config values**: `params.ragApiBase` in `config.toml` (public — safe to
  commit, same as `commentsApiBase`). The Voyage AI key and Anthropic API key
  stay in `terraform.tfvars` (gitignored), passed to the Lambda as environment
  variables via Terraform.
- **Manual setup required before this goes live** (not automated by me — infra
  changes and secrets are the user's call):
  1. Create a Voyage AI account/API key (https://dashboard.voyageai.com) and an
     Anthropic API key (https://console.anthropic.com)
  2. Add `voyage_api_key` and `anthropic_api_key` to `terraform/terraform.tfvars`
     (see `terraform/terraform.tfvars.example`)
  3. `terraform apply` from `terraform/` (creates the S3 bucket, Lambda, API
     Gateway — same review process as any other infra change)
  4. Set `params.ragApiBase` in `config.toml` to the `terraform output
     rag_api_endpoint` value
  5. Add a Jenkins secret-text credential named `voyage-api-key` (Manage Jenkins
     → Credentials) so the `Rebuild RAG Index` stage can call Voyage AI
  6. Confirm the IAM identity behind the existing `aws-blog-deploy-creds` Jenkins
     credential has `s3:PutObject` on `www.kanjtomi1967.net-rag-index` (Terraform
     only grants the Lambda's *read* access to that bucket; the Jenkins indexer
     needs *write* access using the same deploy credentials already used for
     `aws s3 sync`)
- **Build**: like `lambda-comments/`, `lambda-rag/` is a Maven project producing
  a shaded fat JAR (`mvn package` → `target/rag-lambda.jar`), which Terraform's
  `aws_lambda_function.rag` deploys directly — build before `terraform apply`.
- **Cost**: Voyage AI's free tier comfortably covers a personal blog's corpus;
  Claude Haiku 4.5 calls are pennies per question and gated by Turnstile + API
  Gateway throttling; the extra Lambda/API Gateway/S3 usage is within or near
  free tier, similar to the comment system.

## Out of Scope

- No user login/accounts (comments are anonymous + name field only)
- No likes/reactions
