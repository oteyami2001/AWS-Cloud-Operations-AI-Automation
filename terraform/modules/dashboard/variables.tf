variable "name_prefix" {
  type = string
}

variable "dashboard_function_arn" {
  type = string
}

variable "function_names" {
  type = list(string)
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

variable "alarm_arns" {
  type = list(string)
}
