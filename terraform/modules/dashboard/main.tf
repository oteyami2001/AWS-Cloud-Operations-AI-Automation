# Operations dashboard: incident table (Lambda custom widget) + workload and platform metrics.
data "aws_region" "current" {}

locals {
  region = data.aws_region.current.name
  ecs    = ["ClusterName", var.cluster_name, "ServiceName", var.service_name]
  alb    = ["LoadBalancer", var.alb_arn_suffix]
  tg     = ["TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix]
}

resource "aws_cloudwatch_dashboard" "ops" {
  dashboard_name = "${var.name_prefix}-operations"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2
        properties = {
          markdown = "## ${var.name_prefix} - AIOps Cloud Operations\nIncidents are detected by CloudWatch alarms, analysed by Lambda (+ optional Amazon Bedrock) and remediated **only after human approval** via SSM Automation. Runbook: `docs/runbooks/operator-runbook.md`"
        }
      },
      {
        type = "custom", x = 0, y = 2, width = 24, height = 9
        properties = {
          title    = "Incidents (latest 25) - severity, status, AI analysis, resolution history"
          endpoint = var.dashboard_function_arn
          params   = { limit = 25 }
          updateOn = { refresh = true, resize = false, timeRange = false }
        }
      },
      {
        type = "metric", x = 0, y = 11, width = 8, height = 6
        properties = {
          title   = "Incidents opened / resolved"
          region  = local.region
          stat    = "Sum"
          period  = 300
          view    = "timeSeries"
          metrics = [[{ expression = "SEARCH('{AIOps,Category,Severity} MetricName=\"IncidentsOpened\"', 'Sum', 300)", id = "o", label = "" }], [{ expression = "SEARCH('{AIOps,Category,Severity} MetricName=\"IncidentsResolved\"', 'Sum', 300)", id = "r", label = "" }]]
        }
      },
      {
        type = "metric", x = 8, y = 11, width = 8, height = 6
        properties = {
          title   = "Time to recover (seconds)"
          region  = local.region
          period  = 300
          view    = "timeSeries"
          metrics = [[{ expression = "SEARCH('{AIOps,Category,Severity} MetricName=\"TimeToRecoverSeconds\"', 'Average', 300)", id = "m", label = "" }]]
        }
      },
      {
        type       = "alarm", x = 16, y = 11, width = 8, height = 6
        properties = { title = "Workload alarms", alarms = var.alarm_arns }
      },
      {
        type = "metric", x = 0, y = 17, width = 8, height = 6
        properties = {
          title   = "ECS CPU / memory %"
          region  = local.region
          stat    = "Average"
          period  = 60
          metrics = [concat(["AWS/ECS", "CPUUtilization"], local.ecs), concat(["AWS/ECS", "MemoryUtilization"], local.ecs)]
        }
      },
      {
        type = "metric", x = 8, y = 17, width = 8, height = 6
        properties = {
          title   = "Target health"
          region  = local.region
          stat    = "Maximum"
          period  = 60
          metrics = [concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg), concat(["AWS/ApplicationELB", "UnHealthyHostCount"], local.tg)]
        }
      },
      {
        type = "metric", x = 16, y = 17, width = 8, height = 6
        properties = {
          title  = "Requests, 5xx, latency p95"
          region = local.region
          period = 60
          metrics = [
            concat(["AWS/ApplicationELB", "RequestCount"], local.alb, [{ stat = "Sum" }]),
            concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.alb, [{ stat = "Sum" }]),
            concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb, [{ stat = "p95", yAxis = "right" }]),
          ]
        }
      },
      {
        type = "metric", x = 0, y = 23, width = 12, height = 6
        properties = {
          title  = "Platform Lambdas: invocations / errors"
          region = local.region
          stat   = "Sum"
          period = 300
          metrics = flatten([for fn in var.function_names : [
            ["AWS/Lambda", "Invocations", "FunctionName", fn],
            ["AWS/Lambda", "Errors", "FunctionName", fn],
          ]])
        }
      },
      {
        type = "log", x = 12, y = 23, width = 12, height = 6
        properties = {
          title  = "Recent application errors"
          region = local.region
          query  = "SOURCE '${var.app_log_group_name}' | fields @timestamp, @message | filter @message like /ERROR|Exception/ | sort @timestamp desc | limit 20"
          view   = "table"
        }
      },
    ]
  })
}
