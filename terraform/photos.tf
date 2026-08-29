# ==========================================================================
# Photo uploads (iPhone -> S3 via presigned URL): S3 (storage, served from
# the main CloudFront distribution at /photos/*) + Lambda (Java, presign
# issuer only) + API Gateway HTTP API
# ==========================================================================

variable "photo_upload_lambda_jar_path" {
  description = "Path to the built photo-upload-lambda shaded JAR"
  type        = string
  default     = "../lambda-photo-upload/target/photo-upload-lambda.jar"
}

# --- S3 bucket for uploaded photos (private, served only via CloudFront/OAC) ---
resource "aws_s3_bucket" "photos" {
  bucket = "${var.site_subdomain}-photos"
}

resource "aws_s3_bucket_public_access_block" "photos" {
  bucket                  = aws_s3_bucket.photos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The upload page PUTs directly to presigned S3 URLs from the browser, which
# needs bucket-level CORS independent of the presign signature itself.
resource "aws_s3_bucket_cors_configuration" "photos" {
  bucket = aws_s3_bucket.photos.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = ["https://${var.site_subdomain}"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

# Bucket policy allowing only CloudFront (via OAC, on the main site
# distribution's /photos/* behavior — see cloudfront.tf) to read objects.
resource "aws_s3_bucket_policy" "photos" {
  bucket = aws_s3_bucket.photos.id
  policy = data.aws_iam_policy_document.photos_bucket_policy.json
}

data "aws_iam_policy_document" "photos_bucket_policy" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.photos.arn}/*"]

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

# --- IAM role for the Lambda function ---
resource "aws_iam_role" "photo_upload_lambda" {
  name = "photo-upload-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "photo_upload_lambda_basic_logs" {
  role       = aws_iam_role.photo_upload_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Only s3:PutObject is needed — the Lambda never reads/lists objects, it
# just signs PUT URLs that the browser uses directly.
resource "aws_iam_role_policy" "photo_upload_lambda_s3" {
  name = "photo-upload-lambda-s3-access"
  role = aws_iam_role.photo_upload_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.photos.arn}/*"
    }]
  })
}

# --- Lambda function ---
resource "aws_lambda_function" "photo_upload" {
  function_name = "blog-photo-upload"
  role          = aws_iam_role.photo_upload_lambda.arn
  handler       = "com.kanjtomi.blog.photoupload.Handler::handleRequest"
  runtime       = "java17"
  memory_size   = 512
  timeout       = 10

  filename         = var.photo_upload_lambda_jar_path
  source_code_hash = filebase64sha256(var.photo_upload_lambda_jar_path)

  environment {
    variables = {
      BUCKET_NAME    = aws_s3_bucket.photos.id
      ADMIN_API_KEY  = var.admin_api_key
      SITE_SUBDOMAIN = var.site_subdomain
    }
  }
}

resource "aws_cloudwatch_log_group" "photo_upload_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.photo_upload.function_name}"
  retention_in_days = 30
}

# --- API Gateway HTTP API ---
resource "aws_apigatewayv2_api" "photo_upload" {
  name          = "blog-photo-upload-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://${var.site_subdomain}"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type", "x-api-key"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "photo_upload_lambda" {
  api_id                 = aws_apigatewayv2_api.photo_upload.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.photo_upload.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_presign" {
  api_id    = aws_apigatewayv2_api.photo_upload.id
  route_key = "POST /presign"
  target    = "integrations/${aws_apigatewayv2_integration.photo_upload_lambda.id}"
}

resource "aws_apigatewayv2_stage" "photo_upload_default" {
  api_id      = aws_apigatewayv2_api.photo_upload.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "photo_upload_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.photo_upload.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.photo_upload.execution_arn}/*/*"
}

output "photo_upload_api_endpoint" {
  value = aws_apigatewayv2_api.photo_upload.api_endpoint
}

output "photos_bucket_name" {
  value = aws_s3_bucket.photos.id
}
