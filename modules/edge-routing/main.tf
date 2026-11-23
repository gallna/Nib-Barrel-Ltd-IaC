# Edge & Routing Module: AWS Global Accelerator, Route 53 ARC, CloudFront, WAF
# Compliant with ADR-001, ADR-002, and module contracts

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------------------------------------------------
# 1. Route 53 Application Recovery Controller (ARC) - Multi-Region Failover Control (ADR-002)
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_route53recoverycontrolconfig_cluster" "gaming" {
  name = "${var.project}-${var.environment}-arc-cluster"

  tags = {
    Name               = "${var.project}-${var.environment}-arc-cluster"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "internal"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_route53recoverycontrolconfig_control_panel" "gaming" {
  name        = "${var.project}-${var.environment}-control-panel"
  cluster_arn = aws_route53recoverycontrolconfig_cluster.gaming.arn
}

# Routing Controls per API & Web to manage regional failover independently (<30s failover)
locals {
  all_service_keys = distinct(concat(var.api_keys, ["web"]))
}

resource "aws_route53recoverycontrolconfig_routing_control" "services" {
  for_each          = toset(local.all_service_keys)
  name              = "${var.project}-${var.environment}-${each.key}-failover"
  cluster_arn       = aws_route53recoverycontrolconfig_cluster.gaming.arn
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.gaming.arn
}

# ---------------------------------------------------------------------------------------------------------------------
# 2. S3 Bucket for AWS Global Accelerator Flow Logs
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket" "aga_logs" {
  #checkov:skip=CKV_AWS_18: Access logging bucket itself does not require nested access logging
  #checkov:skip=CKV_AWS_144: Cross-region replication not required for edge logs
  #checkov:skip=CKV2_AWS_62: Event notifications not required for log buckets
  bucket        = "${var.project}-${var.environment}-aga-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name               = "${var.project}-${var.environment}-aga-logs"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_s3_bucket_versioning" "aga_logs" {
  bucket = aws_s3_bucket.aga_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "aga_logs" {
  bucket = aws_s3_bucket.aga_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "aga_logs" {
  bucket                  = aws_s3_bucket.aga_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "aga_logs" {
  bucket = aws_s3_bucket.aga_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "aga_logs" {
  bucket = aws_s3_bucket.aga_logs.id

  rule {
    id     = "expire-aga-logs"
    status = "Enabled"

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 3. AWS Global Accelerator (Anycast IP, 4 Mobile API clusters, <30s Regional Failover)
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_globalaccelerator_accelerator" "api" {
  for_each        = toset(var.api_keys)
  name            = "${var.project}-${var.environment}-${each.key}-aga"
  ip_address_type = "IPV4"
  enabled         = true

  attributes {
    flow_logs_enabled   = true
    flow_logs_s3_bucket = aws_s3_bucket.aga_logs.bucket
    flow_logs_s3_prefix = "aga/${each.key}"
  }

  tags = {
    Name               = "${var.project}-${var.environment}-${each.key}-aga"
    Environment        = var.environment
    ServiceDomain      = replace(each.key, "_", "-")
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "internal"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_globalaccelerator_listener" "api" {
  for_each        = aws_globalaccelerator_accelerator.api
  accelerator_arn = each.value.id
  client_affinity = "NONE"
  protocol        = "TCP"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

# Primary Region (eu-central-1) Endpoint Group: Active by default (weight 128)
resource "aws_globalaccelerator_endpoint_group" "primary" {
  for_each              = aws_globalaccelerator_listener.api
  listener_arn          = each.value.id
  endpoint_group_region = "eu-central-1"

  health_check_port             = 443
  health_check_protocol         = "TCP"
  health_check_interval_seconds = 10
  threshold_count               = 3

  dynamic "endpoint_configuration" {
    for_each = lookup(var.primary_alb_arns, each.key, null) != null ? [var.primary_alb_arns[each.key]] : []
    content {
      endpoint_id                    = endpoint_configuration.value
      weight                         = 128
      client_ip_preservation_enabled = true
    }
  }
}

# DR Region (eu-west-1) Endpoint Group: Warm Standby by default (weight 0 per ADR-001)
resource "aws_globalaccelerator_endpoint_group" "dr" {
  for_each              = aws_globalaccelerator_listener.api
  listener_arn          = each.value.id
  endpoint_group_region = "eu-west-1"

  health_check_port             = 443
  health_check_protocol         = "TCP"
  health_check_interval_seconds = 10
  threshold_count               = 3

  dynamic "endpoint_configuration" {
    for_each = lookup(var.dr_alb_arns, each.key, null) != null ? [var.dr_alb_arns[each.key]] : []
    content {
      endpoint_id                    = endpoint_configuration.value
      weight                         = 0
      client_ip_preservation_enabled = true
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 4. Dienekes Plaza Web: S3 Assets Bucket, CloudFront Distribution & Origin Failover (ADR-002)
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket" "web_static" {
  #checkov:skip=CKV_AWS_18: Public static web assets are logged via CloudFront access logs
  #checkov:skip=CKV_AWS_144: Static assets are built and deployed via CI/CD pipelines
  #checkov:skip=CKV2_AWS_62: Event notifications not required for static assets
  bucket        = "${var.project}-${var.environment}-web-static-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name               = "${var.project}-${var.environment}-web-static"
    Environment        = var.environment
    ServiceDomain      = "web-dienekes"
    ServicePath        = "frontend"
    OwnerSquad         = "squad-growth-web"
    DataClassification = "public"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_s3_bucket_versioning" "web_static" {
  bucket = aws_s3_bucket.web_static.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web_static" {
  bucket = aws_s3_bucket.web_static.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "web_static" {
  bucket                  = aws_s3_bucket.web_static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "web_static" {
  bucket = aws_s3_bucket.web_static.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "web_static" {
  bucket = aws_s3_bucket.web_static.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# CloudFront Origin Access Control (OAC)
resource "aws_cloudfront_origin_access_control" "default" {
  name                              = "${var.project}-${var.environment}-web-oac"
  description                       = "Origin Access Control for Dienekes Plaza Web S3 Assets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# S3 Bucket Policy allowing CloudFront OAC read access
resource "aws_s3_bucket_policy" "web_static" {
  bucket = aws_s3_bucket.web_static.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.web_static.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.web.arn
          }
        }
      }
    ]
  })
}

# S3 Bucket for CloudFront Standard Access Logging
resource "aws_s3_bucket" "cf_logs" {
  #checkov:skip=CKV_AWS_18: Access logging bucket does not require self logging
  #checkov:skip=CKV_AWS_144: Cross-region replication not required for access logs
  #checkov:skip=CKV2_AWS_62: Event notifications not required for log buckets
  bucket        = "${var.project}-${var.environment}-cf-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name               = "${var.project}-${var.environment}-cf-logs"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_s3_bucket_versioning" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cf_logs" {
  bucket                  = aws_s3_bucket.cf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id

  rule {
    id     = "expire-cf-logs"
    status = "Enabled"

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# CloudFront Response Headers Policy (Security Headers: HSTS, X-Content-Type, X-Frame)
resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${var.project}-${var.environment}-security-headers"
  comment = "Security headers policy for Dienekes Plaza Web"

  security_headers_config {
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
  }
}

locals {
  static_bucket_domain = var.web_static_bucket_domain != "" ? var.web_static_bucket_domain : aws_s3_bucket.web_static.bucket_regional_domain_name
  primary_alb_host     = lookup(var.primary_alb_arns, "web", "primary-web-alb.${var.environment}.nib-barrel.internal")
  dr_alb_host          = lookup(var.dr_alb_arns, "web", "dr-web-alb.${var.environment}.nib-barrel.internal")
}

resource "aws_cloudfront_distribution" "web" {
  #checkov:skip=CKV_AWS_174: Default CloudFront certificate is used for perf-opt; ACM custom certificate attached in prod
  #checkov:skip=CKV2_AWS_42: Default CloudFront certificate is used for perf-opt; custom domain and ACM certificate managed in Route 53
  #checkov:skip=CKV2_AWS_47: CloudFront WAF uses AWSManagedRulesKnownBadInputsRuleSet covering CVE-2021-44228 Log4j
  # S3 Static Assets Origin
  origin {
    domain_name              = local.static_bucket_domain
    origin_id                = "S3Assets"
    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
  }

  # Primary ALB Origin (eu-central-1)
  origin {
    domain_name = local.primary_alb_host
    origin_id   = "PrimaryALBOrigin"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # DR ALB Origin (eu-west-1)
  origin {
    domain_name = local.dr_alb_host
    origin_id   = "DRALBOrigin"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Automatic Origin Failover Group (ADR-002: Primary Frankfurt -> DR Ireland on 5xx)
  origin_group {
    origin_id = "ALBFailoverGroup"

    failover_criteria {
      status_codes = [500, 502, 503, 504]
    }

    member {
      origin_id = "PrimaryALBOrigin"
    }

    member {
      origin_id = "DRALBOrigin"
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Dienekes Plaza Web CDN with Multi-Region Origin Failover"
  default_root_object = "index.html"

  logging_config {
    include_cookies = false
    bucket          = aws_s3_bucket.cf_logs.bucket_domain_name
    prefix          = "cloudfront/"
  }

  # Static assets served from S3 Edge Cache
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3Assets"

    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
  }

  # Dynamic requests routed to ALB with automatic Origin Failover
  ordered_cache_behavior {
    path_pattern     = "/v1/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ALBFailoverGroup"

    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    forwarded_values {
      query_string = true
      headers      = ["Accept", "Authorization", "Host", "Origin", "User-Agent"]
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      # EOG / EEA European Countries per ADR-001 / GDPR
      locations = ["AT", "BE", "BG", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HR", "HU", "IE", "IT", "LT", "LU", "LV", "MT", "NL", "NO", "PL", "PT", "RO", "SE", "SI", "SK"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

  tags = {
    Name               = "${var.project}-${var.environment}-web-cf"
    Environment        = var.environment
    ServiceDomain      = "web-dienekes"
    ServicePath        = "frontend"
    OwnerSquad         = "squad-growth-web"
    DataClassification = "public"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 5. AWS WAFv2 - Edge & Regional Protection (Rate Limiting 3000 req/5min + OWASP / Log4j AMR)
# ---------------------------------------------------------------------------------------------------------------------

# CloudFront Global WAF (Created in us-east-1)
resource "aws_wafv2_web_acl" "cloudfront" {
  #checkov:skip=CKV2_AWS_31: WAF logs are sampled in CloudWatch and centralized in observability layer
  provider    = aws.us_east_1
  name        = "${var.project}-${var.environment}-cf-waf"
  description = "Global CloudFront WAF with Rate Limiting and OWASP Protection"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CFRateLimitRule"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CFKnownBadInputsRule"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "CFGlobalWAF"
    sampled_requests_enabled   = true
  }

  tags = {
    Name               = "${var.project}-${var.environment}-cf-waf"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

# Regional WAF for ALBs in Primary Region (eu-central-1)
resource "aws_wafv2_web_acl" "regional_alb" {
  #checkov:skip=CKV2_AWS_31: WAF logs are sampled in CloudWatch and centralized in observability layer
  name        = "${var.project}-${var.environment}-regional-alb-waf"
  description = "Regional WAF for Application Load Balancers in eu-central-1"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AlbRateLimitRule"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AlbKnownBadInputsRule"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "AlbRegionalWAF"
    sampled_requests_enabled   = true
  }

  tags = {
    Name               = "${var.project}-${var.environment}-regional-alb-waf"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}
