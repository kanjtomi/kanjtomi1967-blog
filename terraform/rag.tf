# ==========================================================================
# RAG "ask this blog" search: S3 (embeddings index) + Lambda (Java) + API Gateway HTTP API
# ==========================================================================

variable "voyage_api_key" {
  description = "Voyage AI API key (embeddings, used both by rag-index at build time and by the Lambda at query time)"
  type        = string
  sensitive   = true
}

variable "anthropic_api_key" {
  description = "Anthropic API key (Claude Haiku 4.5, used by the RAG Lambda to generate grounded answers)"
  type        = string
  sensitive   = true
}

variable "rag_lambda_jar_path" {
  description = "Path to the built rag-lambda shaded JAR"
  type        = string
  default     = "../lambda-rag/target/rag-lambda.jar"
}

variable "mcp_shared_secret" {
  description = "Bearer token required on POST /mcp, passed to Claude as the MCP connector's authorization_token so only Anthropic's backend (not random callers) can invoke the search_blog_posts tool"
  type        = string
  sensitive   = true
}

# --- S3 bucket for the embeddings index (private, no public access) ---
resource "aws_s3_bucket" "rag_index" {
  bucket = "${var.site_subdomain}-rag-index"
}

resource "aws_s3_bucket_public_access_block" "rag_index" {
  bucket                  = aws_s3_bucket.rag_index.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM role for the Lambda function ---
resource "aws_iam_role" "rag_lambda" {
  name = "rag-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rag_lambda_basic_logs" {
  role       = aws_iam_role.rag_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "rag_lambda_s3" {
  name = "rag-lambda-s3-access"
  role = aws_iam_role.rag_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["${aws_s3_bucket.rag_index.arn}/*"]
    }]
  })
}

# --- Lambda function ---
resource "aws_lambda_function" "rag" {
  function_name = "blog-rag"
  role          = aws_iam_role.rag_lambda.arn
  handler       = "com.kanjtomi.blog.rag.Handler::handleRequest"
  runtime       = "java17"
  memory_size   = 512
  timeout       = 20

  filename         = var.rag_lambda_jar_path
  source_code_hash = filebase64sha256(var.rag_lambda_jar_path)

  environment {
    variables = {
      BUCKET_NAME       = aws_s3_bucket.rag_index.id
      INDEX_KEY         = "index.json"
      TURNSTILE_SECRET  = var.turnstile_secret
      VOYAGE_API_KEY    = var.voyage_api_key
      ANTHROPIC_API_KEY = var.anthropic_api_key
      MCP_SHARED_SECRET = var.mcp_shared_secret
      MCP_SERVER_URL    = "${aws_apigatewayv2_api.rag.api_endpoint}/mcp"
    }
  }
}

resource "aws_cloudwatch_log_group" "rag_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.rag.function_name}"
  retention_in_days = 30
}

# --- API Gateway HTTP API ---
resource "aws_apigatewayv2_api" "rag" {
  name          = "blog-rag-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://${var.site_subdomain}"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "rag_lambda" {
  api_id                 = aws_apigatewayv2_api.rag.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.rag.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_ask" {
  api_id    = aws_apigatewayv2_api.rag.id
  route_key = "POST /ask"
  target    = "integrations/${aws_apigatewayv2_integration.rag_lambda.id}"
}

# Called only by Anthropic's backend (via the MCP connector) during POST /ask,
# not by the browser - see the MCP_SHARED_SECRET bearer-auth check in mcp().
resource "aws_apigatewayv2_route" "post_mcp" {
  api_id    = aws_apigatewayv2_api.rag.id
  route_key = "POST /mcp"
  target    = "integrations/${aws_apigatewayv2_integration.rag_lambda.id}"
}

resource "aws_apigatewayv2_stage" "rag_default" {
  api_id      = aws_apigatewayv2_api.rag.id
  name        = "$default"
  auto_deploy = true

  # Cheap backstop against a runaway/scripted caller running up the Claude bill,
  # in addition to the Turnstile check done inside the Lambda itself.
  default_route_settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 2
  }
}

resource "aws_lambda_permission" "rag_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rag.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.rag.execution_arn}/*/*"
}

output "rag_api_endpoint" {
  value = aws_apigatewayv2_api.rag.api_endpoint
}

output "rag_index_bucket_name" {
  value = aws_s3_bucket.rag_index.id
}
