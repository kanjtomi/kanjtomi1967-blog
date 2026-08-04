terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Default provider — used for S3, and for any region-flexible resources.
# Pick your preferred region for S3 bucket location (does not need to match
# CloudFront, which is global).
provider "aws" {
  region = var.aws_region
}

# ACM certificates used by CloudFront MUST be requested in us-east-1,
# regardless of where your other resources live. This aliased provider
# is used only for the acm_certificate resource.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
