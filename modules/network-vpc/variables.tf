variable "environment" {
  type        = string
  description = "Environment name (e.g. perf-opt, prod, staging, dev)"
}

variable "project" {
  type        = string
  description = "Project short identifier"
  default     = "gm"
}

variable "vpc_name" {
  type        = string
  description = "Name of the VPC domain (e.g. core-gaming, standard-gaming)"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC (e.g. 10.30.0.0/16)"
}

variable "azs" {
  type        = list(string)
  description = "List of 3 Availability Zones"
}

variable "nat_eip_count_per_az" {
  type        = number
  description = "Number of Elastic IP addresses per NAT Gateway for SNAT exhaustion protection"
  default     = 2
}

variable "interface_endpoints" {
  type        = list(string)
  description = "List of AWS services for Interface VPC Endpoints"
  default = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "sqs",
    "kinesis-streams",
    "kms",
    "monitoring"
  ]
}

variable "gateway_endpoints" {
  type        = list(string)
  description = "List of AWS services for Gateway VPC Endpoints (S3, DynamoDB)"
  default     = ["s3", "dynamodb"]
}

variable "kms_key_arn" {
  type        = string
  description = "KMS Key ARN for VPC flow logs encryption"
  default     = null
}

variable "enable_flow_logs" {
  type        = bool
  description = "Whether to enable VPC Flow Logs"
  default     = true
}

variable "service_domain" {
  type        = string
  description = "Service domain tag"
  default     = "platform"
}

variable "service_path" {
  type        = string
  description = "Service path tag"
  default     = "shared"
}

variable "owner_squad" {
  type        = string
  description = "Owner squad tag"
  default     = "core-platform"
}

variable "data_classification" {
  type        = string
  description = "Data classification tag"
  default     = "internal"
}

variable "backup_tier" {
  type        = string
  description = "Backup tier tag"
  default     = "critical-dr"
}
