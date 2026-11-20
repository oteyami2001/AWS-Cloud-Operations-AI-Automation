# Human roles.
#   operator        - may view the dashboard and request (approve/reject) a remediation.
#   senior-approver - may give the SECOND approval that HIGH-risk runbooks wait for (aws:approve).
# Separation of duties: the operator role cannot send automation approval signals.
locals {
  operator_role_name    = "${var.name_prefix}-operator"
  approver_arn_prefixes = concat(["arn:${local.part}:sts::${local.account}:assumed-role/${local.operator_role_name}/"], var.extra_approver_arn_prefixes)
}

data "aws_iam_policy_document" "human_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }
    dynamic "condition" {
      for_each = var.require_mfa ? [1] : []
      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "operator" {
  permissions_boundary = var.permissions_boundary_arn
  name                 = local.operator_role_name
  assume_role_policy   = data.aws_iam_policy_document.human_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "operator" {
  # checkov:skip=CKV_AWS_356:ssm:DescribeAutomationExecutions does not support resource-level permissions (read-only).
  statement {
    sid       = "RequestRemediation"
    actions   = ["lambda:InvokeFunctionUrl", "lambda:InvokeFunction"]
    resources = [aws_lambda_function.fn["remediation"].arn]
  }
  statement {
    sid       = "ViewDashboardWidget"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.fn["dashboard"].arn]
  }
  statement {
    sid       = "ReadIncidents"
    actions   = ["dynamodb:GetItem", "dynamodb:Scan", "dynamodb:Query"]
    resources = [local.table, "${local.table}/index/*"]
  }
  statement {
    sid       = "ReadKms"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "ViewAutomation"
    actions   = ["ssm:GetAutomationExecution", "ssm:DescribeAutomationExecutions", "ssm:DescribeAutomationStepExecutions"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "operator" {
  role   = aws_iam_role.operator.id
  policy = data.aws_iam_policy_document.operator.json
}

resource "aws_iam_role_policy_attachment" "operator_cw_read" {
  role       = aws_iam_role.operator.name
  policy_arn = "arn:${local.part}:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_role" "senior_approver" {
  permissions_boundary = var.permissions_boundary_arn
  name                 = "${var.name_prefix}-senior-approver"
  assume_role_policy   = data.aws_iam_policy_document.human_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "senior_approver" {
  # checkov:skip=CKV_AWS_356:ssm:DescribeAutomationExecutions does not support resource-level permissions (read-only).
  statement {
    sid       = "SecondApproval"
    actions   = ["ssm:SendAutomationSignal"]
    resources = ["arn:${local.part}:ssm:${local.region}:${local.account}:automation-execution/*"]
  }
  statement {
    sid       = "ViewAutomation"
    actions   = ["ssm:GetAutomationExecution", "ssm:DescribeAutomationExecutions", "ssm:DescribeAutomationStepExecutions"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "senior_approver" {
  role   = aws_iam_role.senior_approver.id
  policy = data.aws_iam_policy_document.senior_approver.json
}
