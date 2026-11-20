# Shared customer-managed KMS key + secrets for the platform.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  partition  = data.aws_partition.current.partition
}

data "aws_iam_policy_document" "kms" {
  # checkov:skip=CKV_AWS_109:Key policy must grant the account root admin rights; IAM policies scope real use.
  # checkov:skip=CKV_AWS_111:Same as above - standard KMS key policy pattern.
  # checkov:skip=CKV_AWS_356:KMS key policies use "*" to refer to the key itself.
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  # CloudWatch alarms and EventBridge publish to the KMS-encrypted SNS topic / SQS DLQ.
  statement {
    sid       = "AwsServicesPublish"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name_prefix} platform encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.this.key_id
}

# Token that protects the sample app's fault-injection endpoints. Generated here, stored only in
# Secrets Manager (and Terraform state - see docs/security.md), injected into the container by ECS.
resource "random_password" "fault_token" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "fault_token" {
  # checkov:skip=CKV2_AWS_57:Demo-only token; rotation is not meaningful for a fault-injection switch.
  name                    = "${var.name_prefix}/sample-app/fault-token"
  description             = "Fault-injection token for the AIOps demo workload"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = 0 # allow clean re-deploys after `terraform destroy`
}

resource "aws_secretsmanager_secret_version" "fault_token" {
  secret_id     = aws_secretsmanager_secret.fault_token.id
  secret_string = random_password.fault_token.result
}
