# Detection layer: SNS topic, CloudWatch alarms (CPU, memory, app errors, unhealthy targets)
# and an AWS Budget as a cost guardrail. Alarm names end in a "kind" suffix that the incident
# analyzer maps to an incident category (src/aiops/events.py).
locals {
  p        = var.name_prefix
  ecs_dims = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alb_dims = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.p}-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "CloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

# --- Application error metric from logs -------------------------------------
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${local.p}-app-errors"
  log_group_name = var.app_log_group_name
  pattern        = "?ERROR ?Exception ?Traceback"
  metric_transformation {
    name          = "AppErrorCount"
    namespace     = "AIOps/App"
    value         = "1"
    default_value = "0"
  }
}

# --- Workload alarms -----------------------------------------------------------
# Workload alarms have no SNS alarm_actions on purpose: EventBridge routes every state change to
# the analyzer, which sends ONE enriched notification per incident (less alert noise) and
# resolves the incident on the OK transition.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.p}-cpu-high"
  alarm_description   = "ECS service CPU > ${var.cpu_threshold}% for 3 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = local.ecs_dims
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.cpu_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${local.p}-memory-high"
  alarm_description   = "ECS service memory > ${var.memory_threshold}% for 3 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = local.ecs_dims
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.memory_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.p}-alb-5xx"
  alarm_description   = "Targets returned more than ${var.error_5xx_threshold} HTTP 5xx in 2 of 3 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.alb_dims
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.error_5xx_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "${local.p}-app-errors"
  alarm_description   = "Application logged more than ${var.app_error_threshold} errors in 2 of 3 minutes"
  namespace           = "AIOps/App"
  metric_name         = "AppErrorCount"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.app_error_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  depends_on          = [aws_cloudwatch_log_metric_filter.app_errors]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${local.p}-unhealthy-targets"
  alarm_description   = "At least one ALB target is failing health checks"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = local.alb_dims
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  alarm_name          = "${local.p}-no-healthy-targets"
  alarm_description   = "No healthy targets behind the ALB (service down or stopped)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.alb_dims
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no datapoints = no targets at all
}

# --- Platform self-monitoring (pages a human directly) -------------------------
resource "aws_cloudwatch_metric_alarm" "analyzer_errors" {
  alarm_name          = "${local.p}-platform-analyzer-errors"
  alarm_description   = "Incident analyzer Lambda errors - the AIOps platform itself is degraded"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.analyzer_function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.p}-platform-dlq-not-empty"
  alarm_description   = "Events failed processing and landed in the analyzer DLQ"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.dlq_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# --- Cost guardrail -----------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  count        = var.budget_email == "" ? 0 : 1
  name         = "${local.p}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project_tag)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
