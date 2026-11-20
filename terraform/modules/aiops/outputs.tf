output "incident_table_name" {
  value = aws_dynamodb_table.incidents.name
}

output "function_names" {
  value = { for k, f in aws_lambda_function.fn : k => f.function_name }
}

output "dashboard_function_arn" {
  value = aws_lambda_function.fn["dashboard"].arn
}

output "remediation_url" {
  value = aws_lambda_function_url.remediation.function_url
}

output "dlq_name" {
  value = aws_sqs_queue.dlq.name
}

output "operator_role_arn" {
  value = aws_iam_role.operator.arn
}

output "senior_approver_role_arn" {
  value = aws_iam_role.senior_approver.arn
}
