variable "name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "log_group_name" {
  type = string
}

variable "alarm_email" {
  description = "Email subscribed to the alerts topic. Empty = no subscription (wire PagerDuty/Slack separately)."
  type        = string
  default     = ""
}

variable "min_running_tasks" {
  type    = number
  default = 2
}

variable "error_ratio_threshold" {
  description = "Fraction of requests returning 5xx that triggers an alarm (0.01 = 1%)."
  type        = number
  default     = 0.01
}

variable "p99_latency_seconds" {
  type    = number
  default = 1
}
