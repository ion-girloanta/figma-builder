
terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
locals {
  default_tags = {
    Project   = "BiuReg"
    CreatedBy = "Ion"
  }
}
provider "aws" {
  region = "eu-west-1"
  profile = "biureg"

}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.200.0.0/20"
  tags = merge(
    local.default_tags,
    {
    Name = "biureg-vpc"
  })
}

# Subnets
resource "aws_subnet" "public_a" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.200.0.0/24"
  availability_zone = "eu-west-1a"
  tags = merge(
    local.default_tags,
    {
    Name = "public-a"
  })
}

resource "aws_subnet" "public_b" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.200.1.0/24"
  availability_zone = "eu-west-1b"
  tags = merge(
    local.default_tags,
    {
      Name = "public-b"
  })
}

resource "aws_subnet" "public_c" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.200.2.0/24"
  availability_zone = "eu-west-1b"
  tags = merge(
    local.default_tags,
    {
      Name = "public-c"
  })
}

resource "aws_subnet" "private_a" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.200.10.0/24"
  availability_zone = "eu-west-1a"
  tags = merge(
    local.default_tags,
    {
      Name = "private-a"
  })
}

resource "aws_subnet" "private_b" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.200.11.0/24"
  availability_zone = "eu-west-1b"
  tags = merge(
    local.default_tags,
    {
      Name = "private-b"
  })
}

resource "aws_subnet" "private_c" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.200.12.0/24"
  availability_zone = "eu-west-1c"
  tags = merge(
    local.default_tags,
    {
      Name = "private-c"
  })
}

# KMS key
resource "aws_kms_key" "biureg_key" {
  description = "KMS key for BIUReg app"
  enable_key_rotation = true
  tags = local.default_tags
}

# DynamoDB
resource "aws_dynamodb_table" "session_data" {
  name           = "biureg-session"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "sessionId"
  attribute {
    name = "sessionId"
    type = "S"
  }
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.biureg_key.arn
  }
  tags = local.default_tags
}

# S3 for static hosting
resource "aws_s3_bucket" "frontend" {
  bucket = "biureg-frontend-static"
  force_destroy = true
  tags = local.default_tags
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "biureg_lambda_exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
  tags = local.default_tags
}

# Lambda Function (Sample)
resource "aws_lambda_function" "tickets" {
  function_name = "lambda-tickets"
  handler       = "handler.lambda_handler"
  runtime       = "python3.11"
  role          = aws_iam_role.lambda_exec.arn
  filename      = "${path.module}/lambda/tickets/lambda_function.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/tickets/lambda_function.zip")
  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id]
    security_group_ids = []
  }
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.session_data.name
    }
  }
  kms_key_arn = aws_kms_key.biureg_key.arn
  tags = local.default_tags
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name = "/aws/lambda/lambda-tickets"
  retention_in_days = 14
  tags = local.default_tags
}


# Cognito User Pool
resource "aws_cognito_user_pool" "biureg_pool" {
  name = "biureg-user-pool"
  tags = local.default_tags
}

resource "aws_cognito_user_pool_client" "biureg_client" {
  name         = "biureg-client"
  user_pool_id = aws_cognito_user_pool.biureg_pool.id
  generate_secret = false
  allowed_oauth_flows_user_pool_client = true
  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  allowed_oauth_flows = ["code"]
  allowed_oauth_scopes = ["email", "openid", "profile"]
  callback_urls = ["https://reg.biu.ac.il/callback"]
  supported_identity_providers = ["COGNITO"]
}

# API Gateway (Private)
resource "aws_api_gateway_rest_api" "biureg_api" {
  name        = "biureg-private-api"
  description = "Private API for Lambda functions"
  endpoint_configuration {
    types = ["PRIVATE"]
  }
  tags = local.default_tags
}

resource "aws_api_gateway_resource" "tickets" {
  rest_api_id = aws_api_gateway_rest_api.biureg_api.id
  parent_id   = aws_api_gateway_rest_api.biureg_api.root_resource_id
  path_part   = "tickets"
}

resource "aws_api_gateway_method" "tickets_get" {
  rest_api_id   = aws_api_gateway_rest_api.biureg_api.id
  resource_id   = aws_api_gateway_resource.tickets.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.biureg_auth.id
}

resource "aws_api_gateway_integration" "tickets_integration" {
  rest_api_id             = aws_api_gateway_rest_api.biureg_api.id
  resource_id             = aws_api_gateway_resource.tickets.id
  http_method             = aws_api_gateway_method.tickets_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.tickets.invoke_arn
}

# API Gateway Authorizer
resource "aws_api_gateway_authorizer" "biureg_auth" {
  name                   = "biureg-authorizer"
  rest_api_id           = aws_api_gateway_rest_api.biureg_api.id
  authorizer_result_ttl_in_seconds = 300
  identity_source       = "method.request.header.Authorization"
  type                  = "COGNITO_USER_POOLS"
  provider_arns         = [aws_cognito_user_pool.biureg_pool.arn]
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tickets.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.biureg_api.execution_arn}/*/*"
}

# CloudFront Distribution
resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name = "biureg-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior = "always"
  signing_protocol = "sigv4"
}

resource "aws_cloudfront_distribution" "biureg_cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "BIUReg Frontend CDN"
  default_root_object = "index.html"
  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = "S3Origin"

    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }
  default_cache_behavior {
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  tags = merge(
    local.default_tags,
    {
    Name = "biureg-distribution"
  })
}


# Cognito User Pool
resource "aws_cognito_user_pool" "biureg_pool" {
  name = "biureg-user-pool"
  tags = local.default_tags
}

resource "aws_cognito_user_pool_client" "biureg_client" {
  name         = "biureg-client"
  user_pool_id = aws_cognito_user_pool.biureg_pool.id
  generate_secret = false
  allowed_oauth_flows_user_pool_client = true
  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  allowed_oauth_flows = ["code"]
  allowed_oauth_scopes = ["email", "openid", "profile"]
  callback_urls = ["https://reg.biu.ac.il/callback"]
  supported_identity_providers = ["COGNITO"]
}

# API Gateway (Private)
resource "aws_api_gateway_rest_api" "biureg_api" {
  tags = {
    Project    = "BiuReg"
    Created_by = "Ion"
  }
  name        = "biureg-private-api"
  description = "Private API for Lambda functions"
  endpoint_configuration {
    types = ["PRIVATE"]
  }
}

resource "aws_api_gateway_resource" "tickets" {
  rest_api_id = aws_api_gateway_rest_api.biureg_api.id
  parent_id   = aws_api_gateway_rest_api.biureg_api.root_resource_id
  path_part   = "tickets"
}

resource "aws_api_gateway_method" "tickets_get" {
  rest_api_id   = aws_api_gateway_rest_api.biureg_api.id
  resource_id   = aws_api_gateway_resource.tickets.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.biureg_auth.id
}

resource "aws_api_gateway_integration" "tickets_integration" {
  rest_api_id             = aws_api_gateway_rest_api.biureg_api.id
  resource_id             = aws_api_gateway_resource.tickets.id
  http_method             = aws_api_gateway_method.tickets_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.tickets.invoke_arn
}

# API Gateway Authorizer
resource "aws_api_gateway_authorizer" "biureg_auth" {
  name                   = "biureg-authorizer"
  rest_api_id           = aws_api_gateway_rest_api.biureg_api.id
  authorizer_result_ttl_in_seconds = 300
  identity_source       = "method.request.header.Authorization"
  type                  = "COGNITO_USER_POOLS"
  provider_arns         = [aws_cognito_user_pool.biureg_pool.arn]
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tickets.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.biureg_api.execution_arn}/*/*"
}

# CloudFront Distribution
resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name = "biureg-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior = "always"
  signing_protocol = "sigv4"
}

resource "aws_cloudfront_distribution" "biureg_cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "BIUReg Frontend CDN"
  default_root_object = "index.html"
  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = "S3Origin"

    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }
  default_cache_behavior {
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  tags = {
    Name = "biureg-distribution"
  }
}
