variable "project" {
  type    = string
  default = "aiops"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "region" {
  description = "Deployment region. us-east-2: the AWS Organization's SCP denies us-east-1 for regional services (ADR 0003)."
  type        = string
  default     = "us-east-2"
}

variable "owner" {
  description = "Owner tag value (team or person)."
  type        = string
  default     = "platform-engineering"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "allowed_ingress_cidrs" {
  description = "Your public IPv4 address as a /32 - the ONLY source allowed to reach the ALB."
  type        = list(string)
  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for c in var.allowed_ingress_cidrs : can(cidrhost(c, 0)) && endswith(c, "/32")])
    error_message = "allowed_ingress_cidrs must be one or more IPv4 /32 addresses, e.g. [\"203.0.113.10/32\"]."
  }
}

variable "ecr_repository_name" {
  description = "ECR repository created by terraform/bootstrap."
  type        = string
  default     = "aiops-sample-app"
}

variable "image_tag" {
  type    = string
  default = "v1"
}

variable "baseline_desired_count" {
  type    = number
  default = 1
}

variable "max_desired_count" {
  type    = number
  default = 2
}

variable "enable_flow_logs" {
  type    = bool
  default = false
}

variable "enable_container_insights" {
  type    = bool
  default = false
}

variable "lambda_package_path" {
  type    = string
  default = "../../../build/lambda.zip"
}

variable "bedrock_enabled" {
  type    = bool
  default = false
}

variable "bedrock_model_id" {
  type    = string
  default = "anthropic.claude-opus-5-5"
}

variable "bedrock_daily_call_limit" {
  type    = number
  default = 20
}

variable "trusted_principal_arns" {
  description = "Principals allowed to assume the operator/approver roles. Empty = this account's root (i.e. IAM policies decide)."
  type        = list(string)
  default     = []
}

variable "require_mfa" {
  type    = bool
  default = true
}

variable "alert_email" {
  description = "E-mail for incident / platform alerts (SNS). Must be confirmed via the AWS e-mail."
  type        = string
  default     = ""
}
