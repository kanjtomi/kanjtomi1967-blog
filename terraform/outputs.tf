output "site_bucket_name" {
  description = "S3 bucket name for the main site — used in Jenkinsfile BUCKET_NAME"
  value       = aws_s3_bucket.site.id
}

output "site_cloudfront_distribution_id" {
  description = "CloudFront distribution ID for the main site — used in Jenkinsfile DIST_ID"
  value       = aws_cloudfront_distribution.site.id
}

output "site_cloudfront_domain_name" {
  value = aws_cloudfront_distribution.site.domain_name
}

output "apex_cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.apex_redirect.id
}

output "acm_certificate_arn" {
  value = aws_acm_certificate_validation.site.certificate_arn
}
