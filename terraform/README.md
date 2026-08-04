# Terraform — AWS infra for kanjtomi1967.net

Provisions:
- S3 bucket for the site (private, CloudFront OAC only)
- S3 bucket for apex redirect (`kanjtomi1967.net` → `www.kanjtomi1967.net`)
- 2x CloudFront distributions (main site + apex redirect)
- 1x ACM certificate (us-east-1, covers both `www.kanjtomi1967.net` and `kanjtomi1967.net`)
- Route 53 records (A/AAAA for both `www` and apex, ACM DNS validation records)

## Prerequisites

- An existing Route 53 hosted zone for `kanjtomi1967.net`
  (create manually first if you haven't: `aws route53 create-hosted-zone --name kanjtomi1967.net --caller-reference $(date +%s)`,
  then update your domain registrar's NS records to match)
- AWS credentials configured locally (`aws configure` or environment variables)
- Terraform >= 1.5

## Usage

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

First `apply` will take a few minutes — mostly waiting on ACM DNS validation
and CloudFront distribution deployment (CloudFront propagation is often the
slowest step, ~10-20 min).

## After apply: feed outputs into Jenkins

```bash
terraform output site_bucket_name
terraform output site_cloudfront_distribution_id
```

Copy these values into the `Jenkinsfile`'s `BUCKET_NAME` and `DIST_ID`
environment variables (or better: set them as Jenkins job parameters /
credentials instead of hardcoding).

## Notes

- `price_class = "PriceClass_200"` skips the most expensive edge locations
  (mainly South America / some remote regions). Change to `PriceClass_All`
  for full global coverage, or `PriceClass_100` (US/Canada/Europe only) to
  cut cost further — for a personal blog, `PriceClass_100` is often enough.
- State is local by default (`terraform.tfstate`) — fine for solo use, but
  consider migrating to an S3 backend with state locking (DynamoDB) if you
  ever collaborate or want state safety.
