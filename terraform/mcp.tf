# --- MCP server: exposes search_blog_posts as an MCP Tool over Streamable HTTP ---
# Add this file to terraform/ alongside the existing lambda-rag / lambda-comments resources.
# It reuses the existing RAG index bucket (read-only) and its own API Gateway HTTP API.

# voyage_api_key is declared in rag.tf and reused here.

variable "mcp_bearer_token" {
  description = "Shared secret Claude Desktop/Code sends as 'Authorization: Bearer <token>'."
  type        = string
  sensitive   = true
}

resource "aws_iam_role" "mcp_lambda" {
  name = "blog-mcp-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mcp_lambda_basic" {
  role       = aws_iam_role.mcp_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read-only access to the same RAG index bucket blog-rag already reads from.
resource "aws_iam_role_policy" "mcp_lambda_s3_read" {
  name = "blog-mcp-rag-index-read"
  role = aws_iam_role.mcp_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.rag_index.arn}/*" # reuse existing bucket resource
    }]
  })
}

resource "aws_lambda_function" "mcp" {
  function_name = "blog-mcp"
  role          = aws_iam_role.mcp_lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename      = "${path.module}/../mcp-server/mcp-lambda.zip"
  timeout       = 15
  memory_size   = 256

  environment {
    variables = {
      RAG_INDEX_BUCKET = aws_s3_bucket.rag_index.bucket # reuse existing bucket resource
      VOYAGE_API_KEY   = var.voyage_api_key
      MCP_BEARER_TOKEN = var.mcp_bearer_token
    }
  }
}

resource "aws_apigatewayv2_api" "mcp" {
  name          = "blog-mcp"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "mcp" {
  api_id                 = aws_apigatewayv2_api.mcp.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.mcp.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "mcp" {
  api_id    = aws_apigatewayv2_api.mcp.id
  route_key = "POST /mcp"
  target    = "integrations/${aws_apigatewayv2_integration.mcp.id}"
}

resource "aws_apigatewayv2_stage" "mcp" {
  api_id      = aws_apigatewayv2_api.mcp.id
  name        = "$default"
  auto_deploy = true

  # Same conservative throttle as blog-rag: this endpoint calls Voyage AI
  # per request, so keep a scripted caller from running up the bill.
  default_route_settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 2
  }
}

resource "aws_lambda_permission" "mcp_apigw" {
  statement_id  = "AllowAPIGatewayInvokeMCP"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mcp.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.mcp.execution_arn}/*/*"
}

output "mcp_api_endpoint" {
  value = "${aws_apigatewayv2_stage.mcp.invoke_url}/mcp"
}
