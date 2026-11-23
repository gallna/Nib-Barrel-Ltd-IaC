variable "environment" {
  type        = string
  description = "Environment name (e.g. perf-opt, prod, staging, dev)"
  default     = "perf-opt"
}

variable "project" {
  type        = string
  description = "Project short identifier"
  default     = "gm"
}

variable "create_organization" {
  type        = bool
  description = "Whether to create AWS Organizations root and OUs (true if running in AWS Organizations master/management account)"
  default     = true
}

variable "account_list" {
  type        = map(string)
  description = "Map of AWS account logical names to root contact emails"
  default = {
    shared-services = "shared-services@nib-barrel.internal"
    dev             = "dev@nib-barrel.internal"
    staging         = "staging@nib-barrel.internal"
    perf-opt        = "perf-opt@nib-barrel.internal"
    prod            = "prod@nib-barrel.internal"
  }
}

variable "github_org" {
  type        = string
  description = "GitHub Organization or username for OIDC trust"
  default     = "Nib-Barrel-Ltd"
}

variable "github_repo" {
  type        = string
  description = "GitHub Repository name for OIDC trust"
  default     = "Nib-Barrel-Ltd-IaC"
}

variable "enable_service_quotas" {
  type        = bool
  description = "Whether to automatically request Service Quotas via Terraform"
  default     = true
}
