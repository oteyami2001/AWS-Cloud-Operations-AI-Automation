output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "service_arn" {
  value = aws_ecs_service.app.id
}

output "task_definition_family" {
  value = aws_ecs_task_definition.app.family
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.app.arn_suffix
}

output "app_log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "app_log_group_arn" {
  value = aws_cloudwatch_log_group.app.arn
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}
