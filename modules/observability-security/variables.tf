variable "environment" {
  type = string
}

variable "pagerduty_sns_topic_arn" {
  type    = string
  default = ""
}

variable "enable_chaos_experiments" {
  type    = bool
  default = false
}
