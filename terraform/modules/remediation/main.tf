# Approved Systems Manager Automation runbooks + the role they run as.
# The automation role can ONLY touch the one ECS service of this environment.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  documents = {
    RestartEcsService         = "documents/RestartEcsService.yaml"
    RestoreEcsDesiredCount    = "documents/RestoreEcsDesiredCount.yaml"
    ScaleOutEcsService        = "documents/ScaleOutEcsService.yaml"
    RollbackEcsTaskDefinition = "documents/RollbackEcsTaskDefinition.yaml"
  }
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.name
  part    = data.aws_partition.current.partition
}

resource "aws_ssm_document" "runbook" {
  for_each        = local.documents
  name            = "${var.name_prefix}-${each.key}"
  document_type   = "Automation"
  document_format = "YAML"
  content         = file("${path.module}/${each.value}")
}

data "aws_iam_policy_document" "automation_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.part}:ssm:${local.region}:${local.account}:automation-execution/*"]
    }
  }
}

resource "aws_iam_role" "automation" {
  permissions_boundary = var.permissions_boundary_arn
  name                 = "${var.name_prefix}-ssm-automation"
  assume_role_policy   = data.aws_iam_policy_document.automation_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "automation" {
  statement {
    sid       = "ManageOnlyThisService"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [var.service_arn]
  }
  statement {
    sid       = "ReadTaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:ListTaskDefinitions"]
    resources = ["*"] # these ECS read APIs do not support resource-level permissions
  }
}

resource "aws_iam_role_policy" "automation" {
  role   = aws_iam_role.automation.id
  policy = data.aws_iam_policy_document.automation.json
}
