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
- **CloudFront**: origin = S3 bucket via Origin Access Control; custom domain + ACM cert attached
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

## Conventions

- Post filenames: `YYYY-MM-DD-slug.md`
- Front-matter fields: `title`, `date`, `tags`, `draft`
- Tags are used to generate `/tags/<tag>/` index pages automatically via Hugo taxonomy

## Out of Scope

- No user auth, comments, or likes (single-author, publish/browse only per project scope)
- No server-side compute (Lambda/EC2) unless a future feature explicitly requires it
