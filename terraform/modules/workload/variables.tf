variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "kms_key_arn" {
  type = string
}

variable "fault_token_secret_arn" {
  type = string
}

variable "container_image" {
  description = "Full image URI override. Empty = use this module's ECR repo with var.image_tag."
  type        = string
  default     = ""
}

variable "image_tag" {
  type    = string
  default = "v1"
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "task_cpu" {
  type    = number
  default = 256
}

variable "task_memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the demo ALB. Restrict to your own IP."
  type        = list(string)
}

variable "enable_container_insights" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 14
}
