variable "project" {
  type    = string
  default = "aiops"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "us-east-1"
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
  description = "Who can reach the demo ALB. Set to [\"<your-ip>/32\"]."
  type        = list(string)
  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "Set allowed_ingress_cidrs explicitly (e.g. your IP /32)."
  }
}

variable "container_image" {
  type    = string
  default = ""
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
  type    = string
  default = ""
}

variable "budget_email" {
  type    = string
  default = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 50
}
