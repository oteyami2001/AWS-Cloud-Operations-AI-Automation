# EventBridge routing. Events that fail delivery after retries land in the DLQ (alarmed on).
locals {
  rules = {
    alarm_state = {
      description = "Workload alarm state changes -> incident analyzer"
      target      = "analyzer"
      pattern = {
        source        = ["aws.cloudwatch"]
        "detail-type" = ["CloudWatch Alarm State Change"]
        resources     = var.workload_alarm_arns
        detail        = { state = { value = ["ALARM", "OK"] } }
      }
    }
    ecs_task_stopped = {
      description = "Unexpected ECS task stops for the workload service -> incident analyzer"
      target      = "analyzer"
      pattern = {
        source        = ["aws.ecs"]
        "detail-type" = ["ECS Task State Change"]
        detail = {
          clusterArn = [var.cluster_arn]
          group      = ["service:${var.service_name}"]
          lastStatus = ["STOPPED"]
        }
      }
    }
    ssm_automation_status = {
      description = "Approved runbook execution status -> incident status updater"
      target      = "status"
      pattern = {
        source        = ["aws.ssm"]
        "detail-type" = ["EC2 Automation Execution Status-change Notification"]
        detail        = { Definition = values(var.runbook_document_names) }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each      = local.rules
  name          = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.rules
  rule     = aws_cloudwatch_event_rule.this[each.key].name
  arn      = aws_lambda_function.fn[each.value.target].arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 4
  }

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "events" {
  for_each      = local.rules
  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.value.target].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.this[each.key].arn
}
