# ==========================================================================
# Comment system: S3 (storage) + Lambda (Java) + API Gateway HTTP API
# ==========================================================================

variable "turnstile_secret" {
  description = "Cloudflare Turnstile secret key (server-side verification)"
  type        = string
  sensitive   = true
}

variable "admin_api_key" {
  description = "API key required to call /admin/* endpoints (moderation)"
  type        = string
  sensitive   = true
}

variable "comments_lambda_jar_path" {
  description = "Path to the built comments-lambda shaded JAR"
  type        = string
  default     = "../lambda-comments/target/comments-lambda.jar"
}

# --- S3 bucket for comment storage (private, no public access) ---
resource "aws_s3_bucket" "comments" {
  bucket = "${var.site_subdomain}-comments"
}

resource "aws_s3_bucket_public_access_block" "comments" {
  bucket                  = aws_s3_bucket.comments.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM role for the Lambda function ---
resource "aws_iam_role" "comments_lambda" {
  name = "comments-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "comments_lambda_basic_logs" {
  role       = aws_iam_role.comments_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "comments_lambda_s3" {
  name = "comments-lambda-s3-access"
  role = aws_iam_role.comments_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.comments.arn,
        "${aws_s3_bucket.comments.arn}/*"
      ]
    }]
  })
}

# --- Lambda function ---
resource "aws_lambda_function" "comments" {
  function_name = "blog-comments"
  role          = aws_iam_role.comments_lambda.arn
  handler       = "com.kanjtomi.blog.comments.Handler::handleRequest"
  runtime       = "java17"
  memory_size   = 512
  timeout       = 10

  filename         = var.comments_lambda_jar_path
  source_code_hash = filebase64sha256(var.comments_lambda_jar_path)

  environment {
    variables = {
      BUCKET_NAME       = aws_s3_bucket.comments.id
      TURNSTILE_SECRET  = var.turnstile_secret
      ADMIN_API_KEY     = var.admin_api_key
    }
  }
}

resource "aws_cloudwatch_log_group" "comments_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.comments.function_name}"
  retention_in_days = 30
}

# --- API Gateway HTTP API ---
resource "aws_apigatewayv2_api" "comments" {
  name          = "blog-comments-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://${var.site_subdomain}"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type", "x-api-key"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "comments_lambda" {
  api_id                 = aws_apigatewayv2_api.comments.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.comments.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_comments" {
  api_id    = aws_apigatewayv2_api.comments.id
  route_key = "POST /comments"
  target    = "integrations/${aws_apigatewayv2_integration.comments_lambda.id}"
}

resource "aws_apigatewayv2_route" "get_comments" {
  api_id    = aws_apigatewayv2_api.comments.id
  route_key = "GET /comments"
  target    = "integrations/${aws_apigatewayv2_integration.comments_lambda.id}"
}

resource "aws_apigatewayv2_route" "get_admin_pending" {
  api_id    = aws_apigatewayv2_api.comments.id
  route_key = "GET /admin/pending"
  target    = "integrations/${aws_apigatewayv2_integration.comments_lambda.id}"
}

resource "aws_apigatewayv2_route" "post_admin_approve" {
  api_id    = aws_apigatewayv2_api.comments.id
  route_key = "POST /admin/approve"
  target    = "integrations/${aws_apigatewayv2_integration.comments_lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.comments.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.comments.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.comments.execution_arn}/*/*"
}

output "comments_api_endpoint" {
  value = aws_apigatewayv2_api.comments.api_endpoint
}

output "comments_bucket_name" {
  value = aws_s3_bucket.comments.id
}
