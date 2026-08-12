# S8 — Serverless cross-region DR, as code.
#
# Shell version: ../scripts/deploy.sh. Same stack, but here the duplication
# between regions is visible instead of hidden in two browser tabs — every
# regional resource names the provider alias it belongs to.
#
# Written and planned, not applied.

data "aws_caller_identity" "current" {
  provider = aws.primary
}

# ============================================================== DynamoDB =====
# ONE resource, not two. A global table is a single logical table with a
# replica per region; DynamoDB owns the replication. This is the only piece of
# the stack that is not duplicated, and it is why the data survives a region
# loss at all.
resource "aws_dynamodb_table" "orders" {
  provider = aws.primary

  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ItemId"

  attribute {
    name = "ItemId"
    type = "S"
  }

  # Required for global tables — replication is built on the stream.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  replica {
    region_name = var.secondary_region
  }

  point_in_time_recovery {
    enabled = false # lab; costs extra and there is nothing to recover
  }

  lifecycle {
    # A real DR table should never be destroyed by a stray apply. Commented
    # rather than enabled because this one is meant to be torn down.
    # prevent_destroy = true
    ignore_changes = [replica]
  }
}

# =================================================================== IAM =====
# IAM is global, so this is created once with no per-region duplication — the
# counterpoint to everything below it.
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  provider           = aws.primary
  name               = "${var.name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Four actions on one table and its replica — not AmazonDynamoDBFullAccess,
# which is what the course attaches.
data "aws_iam_policy_document" "table_access" {
  statement {
    sid     = "OrdersTableAccess"
    actions = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Scan"]
    resources = [
      aws_dynamodb_table.orders.arn,
      "arn:aws:dynamodb:${var.secondary_region}:${data.aws_caller_identity.current.account_id}:table/${var.table_name}",
    ]
  }
}

resource "aws_iam_role_policy" "table_access" {
  provider = aws.primary
  name     = "table-access"
  role     = aws_iam_role.lambda.id
  policy   = data.aws_iam_policy_document.table_access.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  provider   = aws.primary
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "handler" {
  type        = "zip"
  source_file = "${path.module}/../src/handler.py"
  output_path = "${path.module}/build/handler.zip"
}

# ============================================== per-region compute (x2) ======
# From here down, every resource exists twice. Terraform cannot for_each over
# providers — an alias is not a value — so the duplication is explicit. That
# limitation is exactly why real multi-region stacks put this in a MODULE and
# call it twice with different providers. Kept flat here so the pattern is
# visible rather than hidden behind a module boundary.

resource "aws_lambda_function" "primary" {
  provider = aws.primary

  function_name    = "${var.name}-api"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12" # the course says 3.9, which is EOL in Lambda
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = var.table_name
      REGION_TAG = var.primary_region
    }
  }
}

resource "aws_lambda_function" "secondary" {
  provider = aws.secondary

  function_name    = "${var.name}-api"
  role             = aws_iam_role.lambda.arn # IAM is global — same role, both regions
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = var.table_name
      REGION_TAG = var.secondary_region
    }
  }
}

resource "aws_apigatewayv2_api" "primary" {
  provider      = aws.primary
  name          = "${var.name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_api" "secondary" {
  provider      = aws.secondary
  name          = "${var.name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_integration" "primary" {
  provider               = aws.primary
  api_id                 = aws_apigatewayv2_api.primary.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.primary.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "secondary" {
  provider               = aws.secondary
  api_id                 = aws_apigatewayv2_api.secondary.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.secondary.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "primary" {
  provider  = aws.primary
  api_id    = aws_apigatewayv2_api.primary.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.primary.id}"
}

resource "aws_apigatewayv2_route" "secondary" {
  provider  = aws.secondary
  api_id    = aws_apigatewayv2_api.secondary.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.secondary.id}"
}

resource "aws_apigatewayv2_stage" "primary" {
  provider    = aws.primary
  api_id      = aws_apigatewayv2_api.primary.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_stage" "secondary" {
  provider    = aws.secondary
  api_id      = aws_apigatewayv2_api.secondary.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "primary" {
  provider      = aws.primary
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.primary.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.primary.execution_arn}/*/*"
}

resource "aws_lambda_permission" "secondary" {
  provider      = aws.secondary
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.secondary.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.secondary.execution_arn}/*/*"
}

# ====================================================== Route 53 failover ====
# Health checks are global and must be created in us-east-1 regardless of what
# they are watching — hence the aws.global alias on both.
#
# Each check targets its region's own API endpoint DIRECTLY, not the failover
# name. Pointing a health check at the record it controls is circular and a
# classic way to build a DR setup that cannot fail back.
resource "aws_route53_health_check" "primary" {
  provider = aws.global

  fqdn              = replace(aws_apigatewayv2_api.primary.api_endpoint, "https://", "")
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = var.health_check_failure_threshold
  request_interval  = var.health_check_interval

  tags = { Name = "${var.name}-primary" }
}

resource "aws_route53_health_check" "secondary" {
  provider = aws.global

  fqdn              = replace(aws_apigatewayv2_api.secondary.api_endpoint, "https://", "")
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = var.health_check_failure_threshold
  request_interval  = var.health_check_interval

  tags = { Name = "${var.name}-secondary" }
}

# Two records, one name. set_identifier distinguishes them; failover_routing_policy
# decides which answers. Route 53 serves SECONDARY only when PRIMARY's health
# check is failing.
resource "aws_route53_record" "primary" {
  provider = aws.global

  zone_id        = var.hosted_zone_id
  name           = var.domain_name
  type           = "CNAME"
  ttl            = var.record_ttl
  set_identifier = "primary"
  records        = [replace(aws_apigatewayv2_api.primary.api_endpoint, "https://", "")]

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary.id
}

resource "aws_route53_record" "secondary" {
  provider = aws.global

  zone_id        = var.hosted_zone_id
  name           = var.domain_name
  type           = "CNAME"
  ttl            = var.record_ttl
  set_identifier = "secondary"
  records        = [replace(aws_apigatewayv2_api.secondary.api_endpoint, "https://", "")]

  failover_routing_policy {
    type = "SECONDARY"
  }

  health_check_id = aws_route53_health_check.secondary.id
}
