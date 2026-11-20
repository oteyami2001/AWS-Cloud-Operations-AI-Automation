# One-time bootstrap: remote state bucket + lock table + GitHub Actions OIDC roles.
#   terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply
# Kept separate (local state) so `envs/dev` can be destroyed without losing CI access.
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "aiops", Environment = "shared", ManagedBy = "terraform" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI roles."
  type        = string
  default     = "oteyami2001/AWS-Cloud-Operations-AI-Automation"
}

data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
}

# --- Terraform state ---------------------------------------------------------
resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_144:Cross-region replication is unnecessary for a demo state bucket.
  # checkov:skip=CKV_AWS_18:Access logging for the state bucket is optional for the demo.
  # checkov:skip=CKV2_AWS_62:Event notifications are not needed for the state bucket.
  # checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is sufficient; avoids a KMS key that outlives envs/dev.
  bucket = "aiops-tfstate-${local.account}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "state_tls" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_dynamodb_table" "locks" {
  # checkov:skip=CKV_AWS_119:Lock table holds no sensitive data; AWS-owned key is sufficient.
  name         = "aiops-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }
}

# --- GitHub Actions OIDC -------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate via its own trust store; the thumbprint is retained for the API.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "plan_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

# Plan role: read-only, usable from any branch / PR of this repository.
resource "aws_iam_role" "plan" {
  name               = "aiops-github-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_assume.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"] },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"], Resource = aws_dynamodb_table.locks.arn },
    ]
  })
}

# Apply role: ONLY from the protected "aws-dev" GitHub environment (which requires a reviewer).
data "aws_iam_policy_document" "apply_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:aws-dev"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "aiops-github-apply"
  assume_role_policy = data.aws_iam_policy_document.apply_assume.json
  # Broad by necessity (it creates IAM roles, VPCs, ECS ...). Bounded by: environment-only trust,
  # required reviewers on the GitHub environment, and the permissions boundary below.
  permissions_boundary = aws_iam_policy.apply_boundary.arn
}

resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "apply_iam" {
  # checkov:skip=CKV_AWS_355:IAM role management for this project's own roles requires "*" on some read APIs.
  role = aws_iam_role.apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ManageProjectRolesOnly"
      Effect = "Allow"
      Action = ["iam:*Role*", "iam:*Policy*", "iam:PassRole", "iam:TagRole", "iam:UntagRole"]
      Resource = [
        "arn:aws:iam::${local.account}:role/aiops-*",
        "arn:aws:iam::${local.account}:policy/aiops-*",
      ]
    }]
  })
}

resource "aws_iam_policy" "apply_boundary" {
  # checkov:skip=CKV_AWS_62:Permissions boundary - the Allow * is intersected with the role's own policies; the Deny statements are the control.
  # checkov:skip=CKV_AWS_63:Permissions boundary pattern (see above).
  # checkov:skip=CKV_AWS_286:Permissions boundary pattern (see above).
  # checkov:skip=CKV_AWS_287:Permissions boundary pattern (see above).
  # checkov:skip=CKV_AWS_288:Permissions boundary pattern (see above).
  # checkov:skip=CKV_AWS_289:Permissions boundary pattern (see above).
  # checkov:skip=CKV_AWS_290:Permissions boundary pattern (see above).
  # checkov:skip=CKV_AWS_355:Permissions boundary pattern (see above).
  # checkov:skip=CKV2_AWS_40:Permissions boundary pattern (see above).
  name        = "aiops-github-apply-boundary"
  description = "Permissions boundary: no IAM users/access keys, no changes to the CI roles or org/billing."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "AllowAll", Effect = "Allow", Action = "*", Resource = "*" },
      { Sid = "NoIamUsersOrKeys", Effect = "Deny", Action = ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile"], Resource = "*" },
      {
        Sid      = "NoSelfEscalation", Effect = "Deny", Action = ["iam:*"],
        Resource = ["arn:aws:iam::${local.account}:role/aiops-github-*", "arn:aws:iam::${local.account}:policy/aiops-github-*"]
      },
      { Sid = "NoOrgOrBilling", Effect = "Deny", Action = ["organizations:*", "account:*", "aws-portal:*"], Resource = "*" },
    ]
  })
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.locks.name
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}
