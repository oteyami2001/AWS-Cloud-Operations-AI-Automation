# One-time, long-lived bootstrap (applied by a human admin with short-lived SSO credentials):
#   - S3 remote state bucket (versioned, encrypted, TLS-only, native S3 lock files)
#   - GitHub Actions OIDC provider + least-privilege plan / apply / image-push roles
#   - Permissions boundary that every workload role created by CI must carry
#   - ECR repository for the sample app (artifact lives outside the destroyable environment)
#   - Account-level AWS Budget with e-mail alerts
# Kept separate from envs/dev so `terraform destroy` of the environment never removes CI access,
# state, or the budget guardrail.
terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
  }
  # Starts with local state. After the first apply, migrate it into the bucket it created:
  # copy backend.tf.example -> backend.tf and run `terraform init -migrate-state` (docs/deployment.md).
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      ManagedBy   = "terraform"
      Repository  = var.github_repository
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  # Every IAM role / policy the CI apply role may manage must start with this prefix.
  workload_prefix = "${var.project}-${var.environment}-"
  oidc_sub_prefix = "repo:${var.github_repository}"
}
