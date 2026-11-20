variable "name_prefix" {
  type = string
}

variable "cidr_block" {
  type    = string
  default = "10.40.0.0/16"
}

variable "enable_flow_logs" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "kms_key_arn" {
  type = string
}
