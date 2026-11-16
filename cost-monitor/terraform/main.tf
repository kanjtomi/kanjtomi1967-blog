# Read-only IAM user for the cost monitor: Cost Explorer queries only.
# Local state (gitignored) - it holds the access key secret.
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

resource "aws_iam_user" "cost_monitor" {
  name = "k8s-cost-monitor"
  tags = { Purpose = "home k8s cost-monitor - read-only Cost Explorer" }   # IAM tag values allow no ( )
}

resource "aws_iam_user_policy" "ce_read" {
  name = "cost-explorer-read"
  user = aws_iam_user.cost_monitor.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ce:GetCostAndUsage", "ce:GetCostForecast"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_access_key" "cost_monitor" {
  user = aws_iam_user.cost_monitor.name
}

output "access_key_id" {
  value = aws_iam_access_key.cost_monitor.id
}

output "secret_access_key" {
  value     = aws_iam_access_key.cost_monitor.secret
  sensitive = true
}
