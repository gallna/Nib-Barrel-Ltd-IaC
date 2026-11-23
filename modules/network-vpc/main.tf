# VPC Module: Networking for Gaming Workloads (3 AZs, 9 Subnets per VPC)
# Strictly compliant with docs/governance/cidr-plan.md

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-vpc"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

# Lockdown Default Security Group per security governance (CKV2_AWS_12)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-default-sg-locked"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-igw"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

# Subnets per docs/governance/cidr-plan.md Section 3:
# Public: AZ-1 (.0.0/22, netnum=0), AZ-2 (.4.0/22, netnum=1), AZ-3 (.8.0/22, netnum=2)
# Isolated Data: AZ-1 (.16.0/22, netnum=4), AZ-2 (.20.0/22, netnum=5), AZ-3 (.24.0/22, netnum=6)
# Private App: AZ-1 (.32.0/19, netnum=1), AZ-2 (.64.0/19, netnum=2), AZ-3 (.96.0/19, netnum=3)
locals {
  public_netnums = [0, 1, 2]
  data_netnums   = [4, 5, 6]
  app_netnums    = [1, 2, 3]
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 6, local.public_netnums[count.index])
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-public-az${count.index + 1}"
    Environment        = var.environment
    Tier               = "public"
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_subnet" "data" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 6, local.data_netnums[count.index])
  availability_zone = var.azs[count.index]

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-data-az${count.index + 1}"
    Environment        = var.environment
    Tier               = "isolated"
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_subnet" "app" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 3, local.app_netnums[count.index])
  availability_zone = var.azs[count.index]

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-app-az${count.index + 1}"
    Environment        = var.environment
    Tier               = "private"
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

# NAT Gateways & Elastic IPs (1 NAT Gateway per AZ with multi-EIP for SNAT protection)
resource "aws_eip" "nat" {
  count  = 3
  domain = "vpc"

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-nat-eip-${count.index + 1}"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_eip" "nat_secondary" {
  count  = var.nat_eip_count_per_az > 1 ? 3 : 0
  domain = "vpc"

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-nat-secondary-eip-${count.index + 1}"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_nat_gateway" "this" {
  count         = 3
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  secondary_allocation_ids = var.nat_eip_count_per_az > 1 ? [
    aws_eip.nat_secondary[count.index].id
  ] : []

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-nat-${count.index + 1}"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }

  depends_on = [aws_internet_gateway.this]
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-public-rt"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "app" {
  count  = 3
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-app-rt-${count.index + 1}"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_route_table_association" "app" {
  count          = 3
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# Isolated Data Subnets (No route to IGW or NAT Gateway)
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-data-rt"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_route_table_association" "data" {
  count          = 3
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# Gateway VPC Endpoints (S3, DynamoDB)
resource "aws_vpc_endpoint" "gateway" {
  for_each          = toset(var.gateway_endpoints)
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id, aws_route_table.data.id], aws_route_table.app[*].id)

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-vpce-${each.value}"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

# Interface VPC Endpoints Security Group
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project}-${var.environment}-${var.vpc_name}-vpce-sg"
  description = "Security group for Interface VPC Endpoints in ${var.vpc_name}"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Allow HTTPS from within VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow HTTPS outbound to VPC endpoints within CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-vpce-sg"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

# Interface VPC Endpoints (ECR, Logs, SecretsManager, SQS, KMS, etc.)
resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(var.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  subnet_ids          = aws_subnet.data[*].id
  private_dns_enabled = true

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-vpce-${replace(each.value, ".", "-")}"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

# VPC Flow Logs (Security and Audit requirement)
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  #checkov:skip=CKV_AWS_338: Operational VPC flow logs retention is set to 14 days per Section 9.1 architecture design with S3 archival
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc-flow-logs/${var.project}-${var.environment}-${var.vpc_name}"
  retention_in_days = 14
  kms_key_id        = var.kms_key_arn

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-flow-logs"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_iam_role" "vpc_flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${var.project}-${var.environment}-${var.vpc_name}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = "internal"
    BackupTier         = "standard"
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${var.project}-${var.environment}-${var.vpc_name}-flow-logs-policy"
  role  = aws_iam_role.vpc_flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "${aws_cloudwatch_log_group.vpc_flow_logs[0].arn}:*"
      }
    ]
  })
}

resource "aws_flow_log" "this" {
  count           = var.enable_flow_logs ? 1 : 0
  iam_role_arn    = aws_iam_role.vpc_flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs[0].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.this.id

  tags = {
    Name               = "${var.project}-${var.environment}-${var.vpc_name}-flow-log"
    Environment        = var.environment
    ServiceDomain      = var.service_domain
    ServicePath        = var.service_path
    OwnerSquad         = var.owner_squad
    DataClassification = var.data_classification
    BackupTier         = var.backup_tier
    ManagedBy          = "opentofu"
    StateLayer         = "01-network-edge"
  }
}
