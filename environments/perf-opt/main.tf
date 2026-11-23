terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
  default_tags {
    tags = {
      Environment        = "perf-opt"
      ServiceDomain      = "platform"
      ServicePath        = "shared"
      OwnerSquad         = "core-platform"
      DataClassification = "confidential"
      BackupTier         = "critical-dr"
      ManagedBy          = "opentofu"
      StateLayer         = "00-foundation"
    }
  }
}

provider "aws" {
  alias  = "dr"
  region = "eu-west-1"
  default_tags {
    tags = {
      Environment        = "perf-opt"
      ServiceDomain      = "platform"
      ServicePath        = "shared"
      OwnerSquad         = "core-platform"
      DataClassification = "confidential"
      BackupTier         = "critical-dr"
      ManagedBy          = "opentofu"
      StateLayer         = "00-foundation"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = {
      Environment        = "perf-opt"
      ServiceDomain      = "platform"
      ServicePath        = "shared"
      OwnerSquad         = "core-platform"
      DataClassification = "confidential"
      BackupTier         = "critical-dr"
      ManagedBy          = "opentofu"
      StateLayer         = "00-foundation"
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 1. Foundation Layer (00-foundation): IAM OIDC, KMS Keys, Service Quotas
# ---------------------------------------------------------------------------------------------------------------------
module "foundation" {
  source = "../../modules/foundation"

  environment           = "perf-opt"
  project               = "gm"
  create_organization   = false # Managed externally or in management account
  enable_service_quotas = true
  github_org            = "Nib-Barrel-Ltd"
  github_repo           = "Nib-Barrel-Ltd-IaC"

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 2. Network & VPC Layer (01-network-edge) - Primary Region (eu-central-1)
# ---------------------------------------------------------------------------------------------------------------------
module "vpc_core_gaming_primary" {
  source = "../../modules/network-vpc"

  environment          = "perf-opt"
  project              = "gm"
  vpc_name             = "core-gaming"
  vpc_cidr             = "10.10.0.0/16"
  azs                  = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  nat_eip_count_per_az = 2
  kms_key_arn          = module.foundation.kms_general_primary_arn

  service_domain      = "platform"
  service_path        = "shared"
  owner_squad         = "core-platform"
  data_classification = "confidential"
  backup_tier         = "critical-dr"
}

module "vpc_standard_gaming_primary" {
  source = "../../modules/network-vpc"

  environment          = "perf-opt"
  project              = "gm"
  vpc_name             = "standard-gaming"
  vpc_cidr             = "10.11.0.0/16"
  azs                  = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  nat_eip_count_per_az = 2
  kms_key_arn          = module.foundation.kms_general_primary_arn

  service_domain      = "platform"
  service_path        = "shared"
  owner_squad         = "core-platform"
  data_classification = "confidential"
  backup_tier         = "critical-dr"
}

# ---------------------------------------------------------------------------------------------------------------------
# 3. Network & VPC Layer (01-network-edge) - DR Region (eu-west-1)
# ---------------------------------------------------------------------------------------------------------------------
module "vpc_core_gaming_dr" {
  source = "../../modules/network-vpc"

  environment          = "perf-opt"
  project              = "gm"
  vpc_name             = "core-gaming-dr"
  vpc_cidr             = "10.20.0.0/16"
  azs                  = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  nat_eip_count_per_az = 2
  kms_key_arn          = module.foundation.kms_general_dr_arn

  service_domain      = "platform"
  service_path        = "shared"
  owner_squad         = "core-platform"
  data_classification = "confidential"
  backup_tier         = "critical-dr"
}

module "vpc_standard_gaming_dr" {
  source = "../../modules/network-vpc"

  environment          = "perf-opt"
  project              = "gm"
  vpc_name             = "standard-gaming-dr"
  vpc_cidr             = "10.21.0.0/16"
  azs                  = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  nat_eip_count_per_az = 2
  kms_key_arn          = module.foundation.kms_general_dr_arn

  service_domain      = "platform"
  service_path        = "shared"
  owner_squad         = "core-platform"
  data_classification = "confidential"
  backup_tier         = "critical-dr"
}

# ---------------------------------------------------------------------------------------------------------------------
# 4. Edge Routing Layer (Global Accelerator, Route 53 ARC, CloudFront, WAF)
# ---------------------------------------------------------------------------------------------------------------------
module "edge_routing" {
  source = "../../modules/edge-routing"

  environment         = "perf-opt"
  project             = "gm"
  api_keys            = ["api_1", "api_2", "api_3", "api_4"]
  waf_rate_limit_5min = 3000

  # For M1 bootstrapping, map placeholder ALB ARNs or outputs from ALBs
  primary_alb_arns = {
    api_1 = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/app/gm-perf-opt-euc1-api1-alb/1234567890abcdef"
    api_2 = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/app/gm-perf-opt-euc1-api2-alb/1234567890abcdef"
    api_3 = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/app/gm-perf-opt-euc1-api3-alb/1234567890abcdef"
    api_4 = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/app/gm-perf-opt-euc1-api4-alb/1234567890abcdef"
    web   = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/app/gm-perf-opt-euc1-web-alb/1234567890abcdef"
  }

  dr_alb_arns = {
    api_1 = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/gm-perf-opt-euw1-api1-alb/1234567890abcdef"
    api_2 = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/gm-perf-opt-euw1-api2-alb/1234567890abcdef"
    api_3 = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/gm-perf-opt-euw1-api3-alb/1234567890abcdef"
    api_4 = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/gm-perf-opt-euw1-api4-alb/1234567890abcdef"
    web   = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/gm-perf-opt-euw1-web-alb/1234567890abcdef"
  }

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# 5. Observability & Security Skeleton (AMP, AMG, SNS Alerts)
# ---------------------------------------------------------------------------------------------------------------------
module "observability_security" {
  source = "../../modules/observability-security"

  environment              = "perf-opt"
  enable_chaos_experiments = true
}
