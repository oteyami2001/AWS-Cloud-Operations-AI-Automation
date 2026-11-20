output "app_url" {
  value = "http://${module.workload.alb_dns_name}"
}

output "ecr_repository_url" {
  value = module.workload.ecr_repository_url
}

output "cluster_name" {
  value = module.workload.cluster_name
}

output "service_name" {
  value = module.workload.service_name
}

output "incident_table" {
  value = module.aiops.incident_table_name
}

output "remediation_url" {
  description = "IAM-authenticated approval endpoint (use scripts/approve.py)."
  value       = module.aiops.remediation_url
}

output "operator_role_arn" {
  value = module.aiops.operator_role_arn
}

output "senior_approver_role_arn" {
  value = module.aiops.senior_approver_role_arn
}

output "fault_token_secret_arn" {
  value = module.security.fault_token_secret_arn
}

output "dashboard_url" {
  value = local.dashboard_url
}

output "alarm_names" {
  value = module.monitoring.alarm_names
}
