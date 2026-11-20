variable "name_prefix" {
  type = string
}

variable "service_arn" {
  description = "ARN of the single ECS service the runbooks may modify."
  type        = string
}
