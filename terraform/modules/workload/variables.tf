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
  description = "Full image URI, preferably pinned by digest (repo@sha256:...)."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR repository the execution role may pull from."
  type        = string
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
  description = "Single-host IPv4 CIDRs (/32) allowed to reach the demo ALB on port 80."
  type        = list(string)
  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for c in var.allowed_ingress_cidrs : can(cidrhost(c, 0)) && endswith(c, "/32")])
    error_message = "allowed_ingress_cidrs must be one or more IPv4 /32 addresses (no wider ranges, no 0.0.0.0/0)."
  }
}

variable "enable_container_insights" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every IAM role in this module (from terraform/bootstrap)."
  type        = string
  default     = null
}
