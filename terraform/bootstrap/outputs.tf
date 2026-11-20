output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}

output "image_push_role_arn" {
  value = aws_iam_role.image_push.arn
}

output "workload_boundary_arn" {
  value = aws_iam_policy.workload_boundary.arn
}

output "ecr_repository_name" {
  value = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_repository_variables" {
  description = "Values to set as GitHub repository variables (Settings > Secrets and variables > Actions > Variables)."
  value = {
    AWS_REGION              = var.region
    TF_STATE_BUCKET         = aws_s3_bucket.state.bucket
    AWS_PLAN_ROLE_ARN       = aws_iam_role.plan.arn
    AWS_APPLY_ROLE_ARN      = aws_iam_role.apply.arn
    AWS_IMAGE_PUSH_ROLE_ARN = aws_iam_role.image_push.arn
    ECR_REPOSITORY          = aws_ecr_repository.app.name
  }
}
