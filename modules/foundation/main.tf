# Foundation Module: AWS Organizations, SCPs, IAM OIDC, Multi-Region KMS

data "aws_caller_identity" "current" {}

# Standard KMS Policy delegating full key management to IAM root
data "aws_iam_policy_document" "kms_key_policy" {
  #checkov:skip=CKV_AWS_111: KMS key policy requires Resource * to delegate administration to account IAM
  #checkov:skip=CKV_AWS_109: KMS key policy requires Resource * to delegate administration to account IAM
  #checkov:skip=CKV_AWS_356: KMS key policy requires Resource * to delegate administration to account IAM
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

# 1. AWS Organizations Structure & Accounts
resource "aws_organizations_organization" "org" {
  count       = var.create_organization ? 1 : 0
  feature_set = "ALL"
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "servicequotas.amazonaws.com"
  ]
}

resource "aws_organizations_organizational_unit" "gaming_ou" {
  count     = var.create_organization ? 1 : 0
  name      = "Gaming-Workloads"
  parent_id = aws_organizations_organization.org[0].roots[0].id
}

resource "aws_organizations_account" "accounts" {
  for_each  = var.create_organization ? var.account_list : {}
  name      = "${var.project}-${each.key}"
  email     = each.value
  parent_id = aws_organizations_organizational_unit.gaming_ou[0].id

  tags = {
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "confidential"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "00-foundation"
  }
}

# 2. Service Control Policy (SCP) restricting regions to EU (eu-central-1, eu-west-1)
resource "aws_organizations_policy" "eu_region_restriction" {
  count       = var.create_organization ? 1 : 0
  name        = "EURegionRestrictionSCP"
  description = "Restricts AWS resource creation to eu-central-1 and eu-west-1 for GDPR and data sovereignty"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RestrictRegionsToEU"
        Effect = "Deny"
        NotAction = [
          "iam:*",
          "route53:*",
          "route53recoverycontrolconfig:*",
          "route53recoveryreadiness:*",
          "cloudfront:*",
          "globalaccelerator:*",
          "wafv2:*",
          "support:*",
          "sts:*",
          "organizations:*",
          "budgets:*",
          "health:*",
          "shield:*"
        ]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = [
              "eu-central-1",
              "eu-west-1"
            ]
          }
        }
      }
    ]
  })

  tags = {
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "confidential"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "00-foundation"
  }
}

resource "aws_organizations_policy_attachment" "scp_attachment" {
  count     = var.create_organization ? 1 : 0
  policy_id = aws_organizations_policy.eu_region_restriction[0].id
  target_id = aws_organizations_organizational_unit.gaming_ou[0].id
}

# 3. IAM OIDC Provider for CI/CD (GitHub Actions)
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c5824a6f5a0c16161da3921b32c4b1231102910"
  ]

  tags = {
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "cicd-devex"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "00-foundation"
  }
}

resource "aws_iam_role" "ci_cd_oidc" {
  name = "${var.project}-${var.environment}-cicd-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = {
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "cicd-devex"
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "00-foundation"
  }
}

resource "aws_iam_role_policy_attachment" "admin_access" {
  #checkov:skip=CKV_AWS_274: CI/CD bootstrap role requires broad permissions to provision multi-account gaming infrastructure
  role       = aws_iam_role.ci_cd_oidc.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# 4. Multi-Region AWS KMS Keys (including Crypto-Shredding per ADR-009)
# Primary General Platform Multi-Region Key (eu-central-1)
resource "aws_kms_key" "multiregion_general" {
  description             = "Multi-Region KMS primary key for gaming platform encryption in ${var.environment}"
  deletion_window_in_days = 30
  multi_region            = true
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key_policy.json

  tags = {
    Name               = "${var.project}-${var.environment}-general-mrk"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "confidential"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "00-foundation"
  }
}

resource "aws_kms_alias" "multiregion_general_alias" {
  name          = "alias/${var.project}-${var.environment}-general"
  target_key_id = aws_kms_key.multiregion_general.key_id
}

# Replica General Platform Multi-Region Key (eu-west-1)
resource "aws_kms_replica_key" "multiregion_general_dr" {
  provider                = aws.dr
  description             = "Multi-Region KMS replica key for gaming platform encryption in ${var.environment} (DR)"
  primary_key_arn         = aws_kms_key.multiregion_general.arn
  deletion_window_in_days = 30

  tags = {
    Name               = "${var.project}-${var.environment}-general-mrk-dr"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "core-platform"
    DataClassification = "confidential"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "00-foundation"
  }
}

resource "aws_kms_alias" "multiregion_general_dr_alias" {
  provider      = aws.dr
  name          = "alias/${var.project}-${var.environment}-general"
  target_key_id = aws_kms_replica_key.multiregion_general_dr.key_id
}

# Crypto-Shredding Multi-Region KMS Key per ADR-009 (GDPR Art. 17) Primary (eu-central-1)
resource "aws_kms_key" "crypto_shredding" {
  description             = "Dedicated Multi-Region KMS primary key for Player PII DEK Crypto-Shredding (GDPR Art. 17) in ${var.environment}"
  deletion_window_in_days = 30
  multi_region            = true
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key_policy.json

  tags = {
    Name               = "${var.project}-${var.environment}-crypto-shredding-mrk"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "data-reliability"
    DataClassification = "pii-gdpr"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "00-foundation"
  }
}

resource "aws_kms_alias" "crypto_shredding_alias" {
  name          = "alias/${var.project}-${var.environment}-crypto-shredding"
  target_key_id = aws_kms_key.crypto_shredding.key_id
}

# Crypto-Shredding Multi-Region KMS Replica Key (eu-west-1)
resource "aws_kms_replica_key" "crypto_shredding_dr" {
  provider                = aws.dr
  description             = "Dedicated Multi-Region KMS replica key for Player PII DEK Crypto-Shredding (GDPR Art. 17) in ${var.environment} (DR)"
  primary_key_arn         = aws_kms_key.crypto_shredding.arn
  deletion_window_in_days = 30

  tags = {
    Name               = "${var.project}-${var.environment}-crypto-shredding-mrk-dr"
    Environment        = var.environment
    ServiceDomain      = "platform"
    ServicePath        = "shared"
    OwnerSquad         = "data-reliability"
    DataClassification = "pii-gdpr"
    BackupTier         = "critical-dr"
    ManagedBy          = "opentofu"
    StateLayer         = "00-foundation"
  }
}

resource "aws_kms_alias" "crypto_shredding_dr_alias" {
  provider      = aws.dr
  name          = "alias/${var.project}-${var.environment}-crypto-shredding"
  target_key_id = aws_kms_replica_key.crypto_shredding_dr.key_id
}
