# kanjtomi1967.net — Blog Source

Personal tech blog built with Hugo, deployed to AWS (S3 + CloudFront + Route 53),
CI/CD via Jenkins running locally on Windows.

## Setup (first time)

1. Install Hugo (extended version, required for PaperMod's SCSS):
   - Windows: `winget install Hugo.Hugo.Extended` (or download from
     https://github.com/gohugoio/hugo/releases)
   - Verify: `hugo version` (must show "extended")

2. Clone this repo, then add the PaperMod theme as a git submodule:
   ```bash
   git submodule add https://github.com/adityatelange/hugo-PaperMod.git themes/PaperMod
   git submodule update --init --recursive
   ```

3. Run locally:
   ```bash
   hugo server -D
   ```
   Open http://localhost:1313

## Writing a new post

```bash
hugo new posts/my-new-post-title.md
```
Edit the file under `content/posts/`, set `draft: false` when ready to publish,
then `git add`, `git commit`, `git push`.

## Deployment

See `CLAUDE.md` and `Jenkinsfile` for the Jenkins pipeline (build → S3 sync →
CloudFront invalidation). Infrastructure (S3 buckets, CloudFront, ACM, Route 53)
is defined in `terraform/`.

## Infrastructure (Terraform)

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

See `terraform/README.md` for details and required variables.
