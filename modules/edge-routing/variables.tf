variable "environment" {
  type        = string
  description = "Environment name (e.g. perf-opt, prod, staging, dev)"
}

variable "project" {
  type        = string
  description = "Project short identifier"
  default     = "gm"
}

variable "api_keys" {
  type        = list(string)
  description = "List of gaming mobile API keys to configure in Global Accelerator and Route 53 ARC"
  default     = ["api_1", "api_2", "api_3", "api_4"]
}

variable "primary_alb_arns" {
  type        = map(string)
  description = "Map of API keys (api_1..api_4, web) to Primary Region ALB ARNs in eu-central-1"
  default     = {}
}

variable "dr_alb_arns" {
  type        = map(string)
  description = "Map of API keys (api_1..api_4, web) to DR Region ALB ARNs in eu-west-1"
  default     = {}
}

variable "waf_rate_limit_5min" {
  type        = number
  description = "AWS WAF rate limit threshold per 5 minutes per IP"
  default     = 3000
}

variable "web_static_bucket_domain" {
  type        = string
  description = "S3 bucket domain name for CloudFront static assets (if empty, a dedicated bucket will be created)"
  default     = ""
}
