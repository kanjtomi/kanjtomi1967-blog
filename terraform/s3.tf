# Main site bucket — PRIVATE, only accessible via CloudFront (OAC), not public
resource "aws_s3_bucket" "site" {
  bucket = var.site_subdomain # e.g. www.kanjtomi1967.net
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy allowing only CloudFront (via OAC) to read objects
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket_policy.json
}

data "aws_iam_policy_document" "site_bucket_policy" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

# NOTE: The apex (kanjtomi1967.net) redirect to www no longer needs its own
# S3 bucket. Instead, a CloudFront Function on the apex distribution
# (see cloudfront.tf) intercepts every request at the edge and returns a
# 301 redirect — no origin fetch happens, so no public bucket is required.
# This avoids conflicts with account-level S3 Block Public Access, and is
# the pattern AWS itself recommends for apex-to-www redirects.
