output "automation_role_arn" {
  value = aws_iam_role.automation.arn
}

output "document_names" {
  value = { for k, d in aws_ssm_document.runbook : k => d.name }
}

output "document_arns" {
  value = [for d in aws_ssm_document.runbook : d.arn]
}
