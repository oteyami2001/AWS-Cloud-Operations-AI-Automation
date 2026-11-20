# One least-privilege role per function. Key property: ONLY the remediation-approval function can
# start SSM Automation, and only for the approved runbook documents. The analyzer (which talks to
# Bedrock) has no write access to ECS or SSM at all.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.name
  part    = data.aws_partition.current.partition
  table   = aws_dynamodb_table.incidents.arn
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fn" {
  for_each           = local.functions
  name               = "${each.value.name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# --- shared baseline: own logs, X-Ray, DLQ, KMS --------------------------------------------
data "aws_iam_policy_document" "base" {
  for_each = local.functions
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fn[each.key].arn}:*"]
  }
  statement {
    sid       = "XRay"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray does not support resource-level permissions
  }
  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "base" {
  for_each = local.functions
  name     = "baseline"
  role     = aws_iam_role.fn[each.key].id
  policy   = data.aws_iam_policy_document.base[each.key].json
}

# --- analyzer: read-only evidence + incident table + notify + Bedrock -------------------------
data "aws_iam_policy_document" "analyzer" {
  statement {
    sid       = "IncidentTable"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
    resources = [local.table, "${local.table}/index/*"]
  }
  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [var.alerts_topic_arn]
  }
  statement {
    sid       = "AlarmEvidence"
    actions   = ["cloudwatch:DescribeAlarmHistory"]
    resources = ["arn:${local.part}:cloudwatch:${local.region}:${local.account}:alarm:${var.name_prefix}-*"]
  }
  statement {
    sid       = "MetricEvidence"
    actions   = ["cloudwatch:GetMetricData"]
    resources = ["*"] # GetMetricData does not support resource-level permissions
  }
  statement {
    sid       = "EcsEvidence"
    actions   = ["ecs:DescribeServices"]
    resources = [var.service_arn]
  }
  statement {
    sid       = "EcsTaskEvidence"
    actions   = ["ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.cluster_arn]
    }
  }
  statement {
    sid       = "TargetHealthEvidence"
    actions   = ["elasticloadbalancing:DescribeTargetHealth"]
    resources = ["*"] # Describe* ELB APIs do not support resource-level permissions
  }
  statement {
    sid       = "LogEvidence"
    actions   = ["logs:FilterLogEvents"]
    resources = ["${var.app_log_group_arn}:*", var.app_log_group_arn]
  }

  dynamic "statement" {
    for_each = var.bedrock_enabled ? [1] : []
    content {
      sid     = "BedrockInvoke"
      actions = var.bedrock_iam_actions
      resources = [
        "arn:${local.part}:bedrock:*::foundation-model/anthropic.*",
        "arn:${local.part}:bedrock:*:${local.account}:inference-profile/*",
      ]
    }
  }
}

resource "aws_iam_role_policy" "analyzer" {
  name   = "analyzer"
  role   = aws_iam_role.fn["analyzer"].id
  policy = data.aws_iam_policy_document.analyzer.json
}

# --- remediation approval: start ONLY the approved runbooks ------------------------------------
data "aws_iam_policy_document" "remediation" {
  statement {
    sid       = "IncidentTable"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [local.table]
  }
  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [var.alerts_topic_arn]
  }
  statement {
    sid     = "StartApprovedRunbooksOnly"
    actions = ["ssm:StartAutomationExecution"]
    resources = concat(
      [for n in values(var.runbook_document_names) : "arn:${local.part}:ssm:${local.region}:${local.account}:automation-definition/${n}:*"],
      ["arn:${local.part}:ssm:${local.region}:${local.account}:automation-execution/*"],
    )
  }
  statement {
    sid       = "TagExecutions"
    actions   = ["ssm:AddTagsToResource"]
    resources = ["arn:${local.part}:ssm:${local.region}:${local.account}:automation-execution/*"]
  }
  statement {
    sid       = "PassAutomationRole"
    actions   = ["iam:PassRole"]
    resources = [var.automation_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "remediation" {
  name   = "remediation"
  role   = aws_iam_role.fn["remediation"].id
  policy = data.aws_iam_policy_document.remediation.json
}

# --- status updater ----------------------------------------------------------------------------
data "aws_iam_policy_document" "status" {
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"]
    resources = [local.table, "${local.table}/index/by_execution_id"]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [var.alerts_topic_arn]
  }
}

resource "aws_iam_role_policy" "status" {
  name   = "status"
  role   = aws_iam_role.fn["status"].id
  policy = data.aws_iam_policy_document.status.json
}

# --- dashboard widget: read-only ---------------------------------------------------------------
data "aws_iam_policy_document" "dashboard" {
  statement {
    actions   = ["dynamodb:Scan", "dynamodb:GetItem"]
    resources = [local.table]
  }
}

resource "aws_iam_role_policy" "dashboard" {
  name   = "dashboard"
  role   = aws_iam_role.fn["dashboard"].id
  policy = data.aws_iam_policy_document.dashboard.json
}
