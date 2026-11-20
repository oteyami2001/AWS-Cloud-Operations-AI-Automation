output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "alarm_names" {
  value = {
    cpu_high           = aws_cloudwatch_metric_alarm.cpu_high.alarm_name
    memory_high        = aws_cloudwatch_metric_alarm.memory_high.alarm_name
    alb_5xx            = aws_cloudwatch_metric_alarm.alb_5xx.alarm_name
    app_errors         = aws_cloudwatch_metric_alarm.app_errors.alarm_name
    unhealthy_targets  = aws_cloudwatch_metric_alarm.unhealthy_targets.alarm_name
    no_healthy_targets = aws_cloudwatch_metric_alarm.no_healthy_targets.alarm_name
  }
}

output "alarm_arns" {
  value = [
    aws_cloudwatch_metric_alarm.cpu_high.arn,
    aws_cloudwatch_metric_alarm.memory_high.arn,
    aws_cloudwatch_metric_alarm.alb_5xx.arn,
    aws_cloudwatch_metric_alarm.app_errors.arn,
    aws_cloudwatch_metric_alarm.unhealthy_targets.arn,
    aws_cloudwatch_metric_alarm.no_healthy_targets.arn,
  ]
}
