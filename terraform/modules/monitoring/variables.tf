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
  description = "E-mail subscribed to the alerts topic (AWS sends a confirmation mail that must be accepted)."
  type        = string
  default     = ""
  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be empty or a valid e-mail address."
  }
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
