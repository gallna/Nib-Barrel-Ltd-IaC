# AWS Service Quotas for 46,313 Peak RPS Gaming Workload (Section 2.5)

# Primary Region (eu-central-1)
resource "aws_servicequotas_service_quota" "fargate_vcpu_primary" {
  count        = var.enable_service_quotas ? 1 : 0
  service_code = "fargate"
  quota_code   = "L-772E27D2" # Fargate On-Demand vCPU resource count
  value        = 10000
}

resource "aws_servicequotas_service_quota" "vpc_eips_primary" {
  count        = var.enable_service_quotas ? 1 : 0
  service_code = "ec2"
  quota_code   = "L-0263D0A3" # Number of EIPs - EC2-VPC Elastic IPs
  value        = 50
}

resource "aws_servicequotas_service_quota" "alb_target_groups_primary" {
  count        = var.enable_service_quotas ? 1 : 0
  service_code = "elasticloadbalancing"
  quota_code   = "L-193D8D70" # Target groups per Application Load Balancer
  value        = 200
}

# DR Region (eu-west-1)
resource "aws_servicequotas_service_quota" "fargate_vcpu_dr" {
  provider     = aws.dr
  count        = var.enable_service_quotas ? 1 : 0
  service_code = "fargate"
  quota_code   = "L-772E27D2" # Fargate On-Demand vCPU resource count
  value        = 10000
}

resource "aws_servicequotas_service_quota" "vpc_eips_dr" {
  provider     = aws.dr
  count        = var.enable_service_quotas ? 1 : 0
  service_code = "ec2"
  quota_code   = "L-0263D0A3" # Number of EIPs - EC2-VPC Elastic IPs
  value        = 50
}

resource "aws_servicequotas_service_quota" "alb_target_groups_dr" {
  provider     = aws.dr
  count        = var.enable_service_quotas ? 1 : 0
  service_code = "elasticloadbalancing"
  quota_code   = "L-193D8D70" # Target groups per Application Load Balancer
  value        = 200
}
