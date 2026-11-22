# Offline plan tests: run with mocked providers, so they need NO AWS credentials and create nothing.
#   terraform -chdir=terraform/envs/dev test
# They assert the security-relevant shape of the plan (least privilege, gating, encryption, cost caps).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-2a", "us-east-2b"] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-2:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_ecs_service" {
    defaults = { id = "arn:aws:ecs:us-east-2:123456789012:service/aiops-dev-cluster/aiops-dev-app" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-2:123456789012:cluster/aiops-dev-cluster" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-2:123456789012:function:mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-2:123456789012:mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-2:123456789012:log-group:mock" }
  }
  mock_resource "aws_cloudwatch_metric_alarm" {
    defaults = { arn = "arn:aws:cloudwatch:us-east-2:123456789012:alarm:mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-2:123456789012:rule/mock" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-2:123456789012:table/mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-2:123456789012:mock" }
  }
  mock_data "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/aiops-dev-workload-boundary" }
  }
  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-2:123456789012:repository/aiops-sample-app"
      repository_url = "123456789012.dkr.ecr.us-east-2.amazonaws.com/aiops-sample-app"
    }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:mock" }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/app/aiops-dev-alb/0123456789abcdef"
      arn_suffix = "app/aiops-dev-alb/0123456789abcdef"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/aiops-dev-tg/0123456789abcdef"
      arn_suffix = "targetgroup/aiops-dev-tg/0123456789abcdef"
    }
  }
  mock_resource "aws_ssm_document" {
    defaults = { arn = "arn:aws:ssm:us-east-2:123456789012:document/mock" }
  }
  mock_resource "aws_lambda_function_url" {
    defaults = { function_url = "https://mock.lambda-url.us-east-2.on.aws/" }
  }
}


variables {
  allowed_ingress_cidrs = ["203.0.113.10/32"]
  lambda_package_path   = "tests/fixtures/empty.zip"
}

run "full_stack_mock_apply" {
  command = apply # mocked providers: nothing is created in AWS

  assert {
    condition     = module.aiops.function_names["analyzer"] == "aiops-dev-incident-analyzer"
    error_message = "unexpected analyzer function name"
  }

  # Human approval endpoint must be IAM-authenticated
  assert {
    condition     = output.remediation_url != null && output.remediation_url != ""
    error_message = "remediation URL missing"
  }

  assert {
    condition     = startswith(output.dashboard_url, "https://us-east-2.console.aws.amazon.com/cloudwatch/")
    error_message = "dashboard URL output malformed"
  }

  assert {
    condition     = length(output.alarm_names) == 6
    error_message = "expected 6 workload alarms (cpu, memory, 5xx, app errors, unhealthy, no healthy)"
  }
}

run "bedrock_off_by_default" {
  command = plan
  assert {
    condition     = var.bedrock_enabled == false
    error_message = "Bedrock must be opt-in (cost + approval)"
  }
}

run "image_is_pinned_by_digest" {
  command = plan
  assert {
    condition     = output.container_image == "123456789012.dkr.ecr.us-east-2.amazonaws.com/aiops-sample-app@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    error_message = "task definition must reference the ECR image by immutable digest"
  }
}

run "ingress_must_be_explicit" {
  command = plan
  variables {
    allowed_ingress_cidrs = []
  }
  expect_failures = [var.allowed_ingress_cidrs]
}

run "ingress_rejects_open_internet" {
  command = plan
  variables {
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.allowed_ingress_cidrs]
}

run "ingress_rejects_ranges_wider_than_32" {
  command = plan
  variables {
    allowed_ingress_cidrs = ["203.0.113.0/24"]
  }
  expect_failures = [var.allowed_ingress_cidrs]
}

run "ingress_rejects_malformed_address" {
  command = plan
  variables {
    allowed_ingress_cidrs = ["not-an-ip/32"]
  }
  expect_failures = [var.allowed_ingress_cidrs]
}
