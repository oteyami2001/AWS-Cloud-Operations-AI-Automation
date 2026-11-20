output "kms_key_arn" {
  value = aws_kms_key.this.arn
}

output "fault_token_secret_arn" {
  value = aws_secretsmanager_secret.fault_token.arn
}
