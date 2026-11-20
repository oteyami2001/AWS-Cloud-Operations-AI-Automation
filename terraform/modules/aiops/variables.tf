variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "lambda_package_path" {
  description = "Path to the Lambda zip produced by scripts/build_lambda.sh."
  type        = string
}

variable "alerts_topic_arn" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_arn" {
  type = string
}

variable "service_name" {
  type = string
}

variable "service_arn" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "app_log_group_name" {
  type = string
}

variable "app_log_group_arn" {
  type = string
}

variable "workload_alarm_arns" {
  type = list(string)
}

variable "automation_role_arn" {
  type = string
}

variable "runbook_document_names" {
  type = map(string)
}

variable "baseline_desired_count" {
  type    = number
  default = 1
}

variable "max_desired_count" {
  type    = number
  default = 2
}

variable "bedrock_enabled" {
  description = "Call Amazon Bedrock for root-cause summaries. false = deterministic rules engine only (no Bedrock cost)."
  type        = bool
  default     = false
}

variable "bedrock_model_id" {
  type    = string
  default = "anthropic.claude-opus-5-5"
}

variable "bedrock_effort" {
  type    = string
  default = "medium"
  validation {
    condition     = contains(["low", "medium", "high"], var.bedrock_effort)
    error_message = "bedrock_effort must be low, medium or high."
  }
}

variable "bedrock_daily_call_limit" {
  description = "Hard cap on Bedrock calls per UTC day (enforced in DynamoDB). Excess incidents use the rules engine."
  type        = number
  default     = 20
}

variable "bedrock_iam_actions" {
  description = "IAM actions granted for Bedrock inference. Verify against the Bedrock docs for your region/endpoint at deploy time."
  type        = list(string)
  default     = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
}

variable "trusted_principal_arns" {
  description = "IAM principals allowed to assume the operator / senior-approver roles."
  type        = list(string)
}

variable "require_mfa" {
  type    = bool
  default = true
}

variable "extra_approver_arn_prefixes" {
  description = "Additional caller-ARN prefixes the approval Lambda accepts (besides the operator role)."
  type        = list(string)
  default     = []
}

variable "dashboard_url" {
  type    = string
  default = ""
}

variable "log_retention_days" {
  type    = number
  default = 14
}
