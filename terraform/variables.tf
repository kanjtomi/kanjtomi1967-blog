variable "aws_region" {
  description = "AWS region for S3 bucket (CloudFront is global regardless)"
  type        = string
  default     = "ap-northeast-1"
}

variable "domain_name" {
  description = "Apex domain name (must already have a Route 53 hosted zone)"
  type        = string
  default     = "kanjtomi1967.net"
}

variable "site_subdomain" {
  description = "Full subdomain the site is served from"
  type        = string
  default     = "www.kanjtomi1967.net"
}
