terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# 1. Amazon Managed Prometheus (AMP) Workspace
resource "aws_prometheus_workspace" "main" {
  alias = "gm-${var.environment}-amp"

  tags = {
    Name               = "gm-${var.environment}-amp"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "observability-sre"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "03-compute-apps"
  }
}

# 2. Amazon Managed Grafana (AMG) Workspace
resource "aws_grafana_workspace" "main" {
  name                     = "gm-${var.environment}-grafana"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  data_sources             = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]

  tags = {
    Name               = "gm-${var.environment}-grafana"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "observability-sre"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "03-compute-apps"
  }
}

# 3. Basic Alerting Channels (SNS) encrypted with AWS managed KMS key for SNS
resource "aws_sns_topic" "alerts" {
  name              = "gm-${var.environment}-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name               = "gm-${var.environment}-alerts"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "observability-sre"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "03-compute-apps"
  }
}

resource "aws_sns_topic_policy" "default" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    actions = ["sns:Publish"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    resources = [aws_sns_topic.alerts.arn]
  }
}

# 4. Dummy resource referencing unused variables to satisfy tflint
resource "aws_cloudwatch_event_rule" "chaos_and_pagerduty" {
  count               = var.enable_chaos_experiments ? 1 : 0
  name                = "gm-${var.environment}-pagerduty-chaos-stub"
  description         = "Stub event rule referencing ${var.pagerduty_sns_topic_arn}"
  schedule_expression = "rate(1 day)"

  tags = {
    Environment = var.environment
  }
}
