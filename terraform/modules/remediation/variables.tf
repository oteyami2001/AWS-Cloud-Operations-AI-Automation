variable "name_prefix" {
  type = string
}

variable "service_arn" {
  description = "ARN of the single ECS service the runbooks may modify."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every IAM role in this module (from terraform/bootstrap)."
  type        = string
  default     = null
}
