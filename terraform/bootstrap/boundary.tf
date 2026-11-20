# Permissions boundary attached to EVERY role the CI apply role creates. Even if the apply role (or
# a compromised pipeline) creates a role with AdministratorAccess attached, that role's effective
# permissions are capped by this boundary: no IAM writes, no org/account/billing, no CloudTrail
# tampering. The apply role cannot create a role WITHOUT this boundary (see ci_roles.tf).
data "aws_iam_policy_document" "workload_boundary" {
  # A boundary is a CEILING: effective permissions = boundary AND the role's own (resource-scoped)
  # policy. It therefore uses Resource "*" and lists only the actions any workload role needs.
  # checkov:skip=CKV_AWS_356:Permissions boundary (ceiling); each role's identity policy scopes resources.
  # checkov:skip=CKV_AWS_111:Same - write actions are bounded here and resource-scoped in role policies.
  # checkov:skip=CKV_AWS_108:Same - GetSecretValue is scoped to one secret by the ECS execution role policy.
  # checkov:skip=CKV_AWS_110:iam:PassRole is limited to project roles that themselves carry this boundary.
  # checkov:skip=CKV_AWS_109:Same as CKV_AWS_356.
  # checkov:skip=CKV_AWS_107:No credential-exposing IAM actions are allowed; IAM writes are explicitly denied.
  statement {
    sid    = "ActionsUsedByWorkloadRoles"
    effect = "Allow"
    actions = [
      # Lambda / ECS / VPC flow log logging + tracing
      "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:Describe*",
      "logs:FilterLogEvents", "logs:GetLogEvents", "logs:StartQuery", "logs:GetQueryResults",
      "xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetTrace*", "xray:BatchGetTraces",
      # incident analyzer evidence + platform data
      "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
      "elasticloadbalancing:Describe*", "ec2:Describe*",
      "ecs:DescribeServices", "ecs:ListTasks", "ecs:DescribeTasks",
      "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:Scan",
      "dynamodb:DescribeTable",
      "sns:Publish", "sns:Get*", "sns:List*", "sqs:SendMessage",
      "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey",
      # ECS task execution (image pull, secret injection)
      "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
      "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret",
      # remediation (approval Lambda, SSM automation role, human operator / senior approver)
      "ssm:StartAutomationExecution", "ssm:GetAutomationExecution", "ssm:DescribeAutomation*",
      "ssm:SendAutomationSignal", "ssm:AddTagsToResource", "ssm:DescribeDocument", "ssm:GetDocument",
      "ecs:UpdateService", "ecs:DescribeTaskDefinition", "ecs:ListTaskDefinitions",
      "lambda:InvokeFunction", "lambda:InvokeFunctionUrl",
      # Phase 4 (Bedrock) - confirm the exact actions when Bedrock is enabled
      "bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassOnlyProjectRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole", "iam:GetRole"]
    resources = ["arn:${local.partition}:iam::${local.account}:role/${local.workload_prefix}*"]
  }

  statement {
    sid    = "NeverAllowed"
    effect = "Deny"
    not_actions = [
      "iam:PassRole", "iam:GetRole",
    ]
    resources = ["arn:${local.partition}:iam::*:*"]
  }

  statement {
    sid    = "NoOrgAccountBillingOrAuditTampering"
    effect = "Deny"
    actions = [
      "organizations:*", "account:*", "aws-portal:*", "billing:*",
      "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "${local.workload_prefix}workload-boundary"
  description = "Permissions boundary for every ${var.project}-${var.environment} workload role."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}
