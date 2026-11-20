# Network-exposure tests for the workload (mocked provider - offline, creates nothing).
#   terraform -chdir=terraform/modules/workload test
mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/mock/1" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock/1" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock" }
  }
}

variables {
  name_prefix              = "aiops-dev"
  vpc_id                   = "vpc-0123456789abcdef0"
  vpc_cidr                 = "10.40.0.0/16"
  public_subnet_ids        = ["subnet-a", "subnet-b"]
  kms_key_arn              = "arn:aws:kms:us-east-1:123456789012:key/mock"
  fault_token_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mock"
  container_image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/aiops-sample-app@sha256:00"
  ecr_repository_arn       = "arn:aws:ecr:us-east-1:123456789012:repository/aiops-sample-app"
  allowed_ingress_cidrs    = ["203.0.113.10/32"]
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/aiops-dev-workload-boundary"
}

run "alb_ingress_is_exactly_the_operator_ip_on_port_80" {
  command = plan
  assert {
    condition     = length(aws_security_group.alb.ingress) == 1
    error_message = "ALB security group must have exactly one ingress rule"
  }
  assert {
    condition = alltrue([for r in aws_security_group.alb.ingress :
      r.from_port == 80 && r.to_port == 80 && r.protocol == "tcp" &&
      toset(coalesce(r.cidr_blocks, [])) == toset(["203.0.113.10/32"]) &&
      length(coalesce(r.ipv6_cidr_blocks, [])) == 0 && length(coalesce(r.security_groups, [])) == 0 && length(coalesce(r.prefix_list_ids, [])) == 0
    ])
    error_message = "ALB ingress must be tcp/80 from the configured /32 only (no IPv6, SG or prefix-list sources)"
  }
  assert {
    condition     = alltrue([for r in aws_security_group.alb.egress : toset(coalesce(r.cidr_blocks, [])) == toset(["10.40.0.0/16"]) && r.from_port == 8080])
    error_message = "ALB egress must only reach tasks inside the VPC on the container port"
  }
}

run "tasks_accept_traffic_only_from_the_alb" {
  command = plan
  assert {
    condition = alltrue([for r in aws_security_group.tasks.ingress :
    length(coalesce(r.cidr_blocks, [])) == 0 && length(coalesce(r.ipv6_cidr_blocks, [])) == 0 && length(coalesce(r.security_groups, [])) == 1 && r.from_port == 8080])
    error_message = "task security group must accept only the ALB security group on the container port"
  }
  assert {
    condition     = alltrue([for r in aws_security_group.tasks.egress : r.from_port == 443 && r.to_port == 443])
    error_message = "task egress must be limited to HTTPS"
  }
}

run "no_public_admin_surfaces" {
  command = plan
  assert {
    condition     = aws_ecs_service.app.enable_execute_command == false
    error_message = "ECS Exec must be disabled"
  }
  assert {
    condition     = aws_lb.this.drop_invalid_header_fields
    error_message = "ALB must drop invalid header fields"
  }
}

run "roles_carry_permissions_boundary" {
  command = plan
  assert {
    condition     = aws_iam_role.execution.permissions_boundary == var.permissions_boundary_arn && aws_iam_role.task.permissions_boundary == var.permissions_boundary_arn
    error_message = "every role must carry the workload permissions boundary"
  }
}

run "wide_ingress_rejected_at_module_level" {
  command = plan
  variables {
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.allowed_ingress_cidrs]
}
