# Four functions share one deployment package (build/lambda.zip, built by scripts/build_lambda.sh).
locals {
  functions = {
    analyzer = {
      name        = "${var.name_prefix}-incident-analyzer"
      handler     = "aiops.handlers.analyzer.handler"
      timeout     = 90
      memory      = 512
      concurrency = 5 # caps blast radius and Bedrock spend during alarm storms
    }
    remediation = {
      name        = "${var.name_prefix}-remediation-approval"
      handler     = "aiops.handlers.remediation.handler"
      timeout     = 30
      memory      = 256
      concurrency = 2
    }
    status = {
      name        = "${var.name_prefix}-remediation-status"
      handler     = "aiops.handlers.status.handler"
      timeout     = 30
      memory      = 256
      concurrency = 2
    }
    dashboard = {
      name        = "${var.name_prefix}-dashboard-widget"
      handler     = "aiops.handlers.dashboard.handler"
      timeout     = 15
      memory      = 256
      concurrency = 2
    }
  }

  common_env = {
    INCIDENT_TABLE           = aws_dynamodb_table.incidents.name
    NOTIFY_TOPIC_ARN         = var.alerts_topic_arn
    NAME_PREFIX              = var.name_prefix
    ECS_CLUSTER              = var.cluster_name
    ECS_SERVICE              = var.service_name
    TARGET_GROUP_ARN         = var.target_group_arn
    APP_LOG_GROUP            = var.app_log_group_name
    AUTOMATION_ROLE_ARN      = var.automation_role_arn
    HIGH_RISK_APPROVER_ARN   = aws_iam_role.senior_approver.arn
    BASELINE_DESIRED_COUNT   = tostring(var.baseline_desired_count)
    MAX_DESIRED_COUNT        = tostring(var.max_desired_count)
    BEDROCK_ENABLED          = tostring(var.bedrock_enabled)
    BEDROCK_MODEL_ID         = var.bedrock_model_id
    BEDROCK_EFFORT           = var.bedrock_effort
    BEDROCK_DAILY_CALL_LIMIT = tostring(var.bedrock_daily_call_limit)
    APPROVER_ARN_PREFIXES    = join(",", local.approver_arn_prefixes)
    DASHBOARD_URL            = var.dashboard_url
  }
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-events-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = var.kms_key_arn
}

data "aws_iam_policy_document" "dlq" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for r in aws_cloudwatch_event_rule.this : r.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.dlq.json
}

resource "aws_cloudwatch_log_group" "fn" {
  # checkov:skip=CKV_AWS_338:14-day retention is a deliberate cost control for the demo; incidents are retained in DynamoDB.
  for_each          = local.functions
  name              = "/aws/lambda/${each.value.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_lambda_function" "fn" {
  # checkov:skip=CKV_AWS_117:Functions call only public AWS APIs; VPC attachment would require NAT/endpoints (cost).
  # checkov:skip=CKV_AWS_272:Code signing is out of scope for the portfolio build; artifact hash is pinned instead.
  for_each                       = local.functions
  function_name                  = each.value.name
  role                           = aws_iam_role.fn[each.key].arn
  handler                        = each.value.handler
  runtime                        = "python3.13"
  architectures                  = ["arm64"]
  filename                       = var.lambda_package_path
  source_code_hash               = filebase64sha256(var.lambda_package_path)
  timeout                        = each.value.timeout
  memory_size                    = each.value.memory
  reserved_concurrent_executions = each.value.concurrency
  kms_key_arn                    = var.kms_key_arn

  environment {
    variables = local.common_env
  }

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.fn]
}

# Human approval endpoint: IAM-authenticated Function URL (SigV4). No anonymous access.
resource "aws_lambda_function_url" "remediation" {
  function_name      = aws_lambda_function.fn["remediation"].function_name
  authorization_type = "AWS_IAM"
}
