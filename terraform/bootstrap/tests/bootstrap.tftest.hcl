# Bootstrap guardrail tests (mocked provider - offline, creates nothing).
#   terraform -chdir=terraform/bootstrap test
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/aiops-dev-workload-boundary" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::aiops-tfstate-123456789012-us-east-1" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:us-east-1:123456789012:repository/aiops-sample-app" }
  }
}

variables {
  budget_email = "owner@example.com"
}

run "oidc_trust_is_exact_and_audience_bound" {
  command = plan

  assert {
    condition     = toset(flatten([for c in data.aws_iam_policy_document.github_trust["apply"].statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"])) == toset(["repo:oteyami2001/AWS-Cloud-Operations-AI-Automation:environment:aws-dev"])
    error_message = "apply role must trust ONLY the protected aws-dev GitHub environment"
  }
  assert {
    condition = toset(flatten([for c in data.aws_iam_policy_document.github_trust["plan"].statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"])) == toset([
      "repo:oteyami2001/AWS-Cloud-Operations-AI-Automation:ref:refs/heads/main",
      "repo:oteyami2001/AWS-Cloud-Operations-AI-Automation:pull_request",
    ])
    error_message = "plan role must trust only main and pull requests of this repository"
  }
  assert {
    condition = alltrue([for k, d in data.aws_iam_policy_document.github_trust :
      alltrue([for c in d.statement[0].condition : c.test == "StringEquals"]) &&
      contains(flatten([for c in d.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:aud"]), "sts.amazonaws.com")
    ])
    error_message = "every trust policy must use StringEquals (no wildcards) and pin the sts.amazonaws.com audience"
  }
}

run "apply_role_cannot_escalate" {
  command = apply # mocked: resolves the boundary ARN, creates nothing
  assert {
    condition = one([for s in data.aws_iam_policy_document.apply.statement : s if s.sid == "ManageProjectRolesWithBoundaryOnly"]).condition != null && contains(
      flatten([for c in one([for s in data.aws_iam_policy_document.apply.statement : s if s.sid == "ManageProjectRolesWithBoundaryOnly"]).condition : c.values if c.variable == "iam:PermissionsBoundary"]),
    "arn:aws:iam::123456789012:policy/aiops-dev-workload-boundary")
    error_message = "role creation / policy changes must require the workload permissions boundary"
  }
  assert {
    condition     = contains(one([for s in data.aws_iam_policy_document.apply.statement : s if s.sid == "ExplicitDenies"]).actions, "iam:DeleteRolePermissionsBoundary")
    error_message = "apply role must not be able to remove permissions boundaries"
  }
  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.apply.statement :
    !contains(coalesce(s.actions, []), "*") && !contains(coalesce(s.actions, []), "iam:*") || s.effect == "Deny"])
    error_message = "apply role must not have wildcard or iam:* allows"
  }
  assert {
    condition     = alltrue([for c in one([for s in data.aws_iam_policy_document.apply.statement : s if s.sid == "ProjectServicesInRegion"]).condition : c.variable == "aws:RequestedRegion" && contains(c.values, "us-east-1")])
    error_message = "service permissions must be limited to the deployment region"
  }
}

run "plan_role_is_describe_only" {
  command = plan
  assert {
    condition = alltrue(flatten([for s in data.aws_iam_policy_document.plan.statement : [
      for a in coalesce(s.actions, []) : !can(regex("^(s3:GetObject|s3:\\*|dynamodb:(Scan|Query|GetItem|\\*)|logs:(GetLogEvents|FilterLogEvents|\\*)|sqs:ReceiveMessage|ssm:GetParameter.*|ecr:(GetDownloadUrlForLayer|BatchGetImage)|kms:Decrypt|secretsmanager:GetSecretValue|\\*)$", a)) || contains(["ReadWriteStateAndLockFile", "RefreshDemoFaultTokenVersion", "DecryptViaSecretsManagerOnly"], s.sid)
    ]]))
    error_message = "plan role must not read application data or secrets"
  }
  assert {
    condition     = alltrue([for r in one([for s in data.aws_iam_policy_document.plan.statement : s if s.sid == "RefreshDemoFaultTokenVersion"]).resources : endswith(r, ":secret:aiops-dev/sample-app/fault-token-*")])
    error_message = "GetSecretValue must be scoped to the demo fault token only"
  }
}

run "state_bucket_is_private_versioned_encrypted" {
  command = plan
  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "state bucket must block all public access"
  }
  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "state bucket must be versioned"
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "state bucket must be encrypted"
  }
  assert {
    condition     = length([for s in data.aws_iam_policy_document.state_bucket.statement : s if s.sid == "DenyInsecureTransport"]) == 1
    error_message = "state bucket must deny non-TLS access"
  }
}

run "budget_alerts_configured" {
  command = plan
  assert {
    condition     = length(aws_budgets_budget.monthly.notification) == 4 && alltrue([for n in aws_budgets_budget.monthly.notification : contains(n.subscriber_email_addresses, "owner@example.com")])
    error_message = "budget must notify the owner at 50/80/100% actual and 100% forecast"
  }
  assert {
    condition     = length(aws_budgets_budget.monthly.cost_filter) == 0
    error_message = "budget must be account-wide (tag filters read $0 until the tag is activated)"
  }
}

run "budget_email_required" {
  command = plan
  variables {
    budget_email = "not-an-email"
  }
  expect_failures = [var.budget_email]
}
