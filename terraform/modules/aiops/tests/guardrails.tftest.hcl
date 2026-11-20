# Guardrail tests for the AIOps core module (mocked provider - offline, creates nothing).
#   terraform -chdir=terraform/modules/aiops test
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:123456789012:function:mock" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:123456789012:table/aiops-dev-incidents" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:aiops-dev-events-dlq" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-1:123456789012:rule/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
}

variables {
  name_prefix            = "aiops-dev"
  kms_key_arn            = "arn:aws:kms:us-east-1:123456789012:key/mock"
  lambda_package_path    = "../../envs/dev/tests/fixtures/empty.zip"
  alerts_topic_arn       = "arn:aws:sns:us-east-1:123456789012:aiops-dev-alerts"
  cluster_name           = "aiops-dev-cluster"
  cluster_arn            = "arn:aws:ecs:us-east-1:123456789012:cluster/aiops-dev-cluster"
  service_name           = "aiops-dev-app"
  service_arn            = "arn:aws:ecs:us-east-1:123456789012:service/aiops-dev-cluster/aiops-dev-app"
  target_group_arn       = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/aiops-dev-tg/1"
  app_log_group_name     = "/aiops-dev/app"
  app_log_group_arn      = "arn:aws:logs:us-east-1:123456789012:log-group:/aiops-dev/app"
  workload_alarm_arns    = ["arn:aws:cloudwatch:us-east-1:123456789012:alarm:aiops-dev-unhealthy-targets"]
  automation_role_arn    = "arn:aws:iam::123456789012:role/aiops-dev-ssm-automation"
  runbook_document_names = { RestartEcsService = "aiops-dev-RestartEcsService" }
  trusted_principal_arns = ["arn:aws:iam::123456789012:root"]
}

run "approval_endpoint_requires_iam_auth" {
  command = apply
  assert {
    condition     = aws_lambda_function_url.remediation.authorization_type == "AWS_IAM"
    error_message = "remediation Function URL must use AWS_IAM auth"
  }
}

run "analyzer_cannot_change_infrastructure" {
  command = plan
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.analyzer.statement :
      alltrue([for a in s.actions : !startswith(a, "ssm:") && a != "ecs:UpdateService" && a != "iam:PassRole"])
    ])
    error_message = "analyzer must not be able to run SSM, update ECS or pass roles"
  }
}

run "only_remediation_function_starts_automation" {
  command = plan
  assert {
    condition = alltrue(flatten([
      for doc in [data.aws_iam_policy_document.analyzer, data.aws_iam_policy_document.status, data.aws_iam_policy_document.dashboard] : [
        for s in doc.statement : !contains(s.actions, "ssm:StartAutomationExecution")
      ]
    ]))
    error_message = "only the remediation-approval function may start SSM Automation"
  }
  assert {
    condition = alltrue([
      for r in one([for s in data.aws_iam_policy_document.remediation.statement : s.resources if s.sid == "StartApprovedRunbooksOnly"]) :
      can(regex(":automation-definition/aiops-dev-RestartEcsService:\\*$|:automation-execution/\\*$", r))
    ])
    error_message = "StartAutomationExecution must be scoped to the approved runbook documents"
  }
}

run "bedrock_permission_only_when_enabled" {
  command = plan
  assert {
    condition     = length([for s in data.aws_iam_policy_document.analyzer.statement : s if s.sid == "BedrockInvoke"]) == 0
    error_message = "no Bedrock permission when bedrock_enabled = false"
  }
}

run "bedrock_permission_when_enabled" {
  command = plan
  variables {
    bedrock_enabled = true
  }
  assert {
    condition     = length([for s in data.aws_iam_policy_document.analyzer.statement : s if s.sid == "BedrockInvoke"]) == 1
    error_message = "Bedrock permission expected when enabled"
  }
}

run "encryption_and_cost_caps" {
  command = plan
  assert {
    condition     = aws_dynamodb_table.incidents.server_side_encryption[0].enabled && aws_dynamodb_table.incidents.point_in_time_recovery[0].enabled
    error_message = "incident table must be KMS-encrypted with PITR"
  }
  assert {
    condition     = alltrue([for f in aws_lambda_function.fn : f.reserved_concurrent_executions <= 5])
    error_message = "every function needs a reserved concurrency cap"
  }
  assert {
    condition     = alltrue([for g in aws_cloudwatch_log_group.fn : g.retention_in_days > 0 && g.kms_key_id != null])
    error_message = "log groups need retention and KMS"
  }
}

run "human_roles_require_mfa_by_default" {
  command = plan
  assert {
    condition     = length(data.aws_iam_policy_document.human_assume.statement[0].condition) == 1
    error_message = "operator/approver role assumption must require MFA by default"
  }
}
