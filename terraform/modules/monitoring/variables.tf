variable "name_prefix" {
  type = string
}

variable "account_id" {
  type = string
}

variable "kms_key_arn" {
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

variable "app_log_group_name" {
  type = string
}

variable "analyzer_function_name" {
  type = string
}

variable "dlq_name" {
  type = string
}

variable "alert_email" {
  description = "Optional e-mail subscribed to the alerts topic (you must confirm the subscription)."
  type        = string
  default     = ""
}

variable "budget_email" {
  description = "Optional e-mail for AWS Budgets alerts. Empty disables the budget."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 50
}

variable "project_tag" {
  description = "Value of the Project cost-allocation tag (activate it in the Billing console)."
  type        = string
}

variable "cpu_threshold" {
  type    = number
  default = 80
}

variable "memory_threshold" {
  type    = number
  default = 80
}

variable "error_5xx_threshold" {
  type    = number
  default = 5
}

variable "app_error_threshold" {
  type    = number
  default = 5
}
