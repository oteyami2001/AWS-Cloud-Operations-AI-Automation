variable "region" {
  description = "Deployment region. us-east-2: the AWS Organization's SCP denies us-east-1 for regional services (ADR 0003)."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  type    = string
  default = "aiops"
}

variable "environment" {
  description = "Environment the CI roles may deploy (role/policy name prefix: <project>-<environment>-)."
  type        = string
  default     = "dev"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI roles (case-sensitive, must match GitHub exactly)."
  type        = string
  default     = "oteyami2001/AWS-Cloud-Operations-AI-Automation"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be owner/repo."
  }
}

variable "github_oidc_immutable_subject" {
  description = "true if the repository's OIDC subject uses immutable IDs (gh api repos/OWNER/REPO/actions/oidc/customization/sub -> use_immutable_subject)."
  type        = bool
  default     = true
}

variable "github_owner_id" {
  description = "Numeric GitHub owner (user/org) ID, used in immutable OIDC subjects. Not a secret."
  type        = string
  default     = "157901928"
  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be numeric."
  }
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID, used in immutable OIDC subjects. Not a secret."
  type        = string
  default     = "1465569992"
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be numeric."
  }
}

variable "github_deploy_environment" {
  description = "GitHub environment (with required reviewers) that the apply role trusts."
  type        = string
  default     = "aws-dev"
}

variable "create_oidc_provider" {
  description = "false if the account already has the token.actions.githubusercontent.com OIDC provider."
  type        = bool
  default     = true
}

variable "budget_email" {
  description = "E-mail address for AWS Budgets alerts (required)."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_email))
    error_message = "budget_email must be a valid e-mail address."
  }
}

variable "monthly_budget_usd" {
  description = "Account-level monthly cost budget."
  type        = number
  default     = 30
}
