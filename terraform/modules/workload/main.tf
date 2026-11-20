# Monitored sample workload: ECR + ECS Fargate service behind an Application Load Balancer.
data "aws_region" "current" {}

locals {
  container_name = "app"
  image          = var.container_image != "" ? var.container_image : "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
}

resource "aws_ecr_repository" "app" {
  name                 = "${var.name_prefix}-sample-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # lets the cleanup procedure remove the repo with images in it
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  # checkov:skip=CKV_AWS_338:14-day retention is a deliberate cost control for the demo (var.log_retention_days).
  name              = "/${var.name_prefix}/app"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_ecs_cluster" "this" {
  # checkov:skip=CKV_AWS_65:Container Insights is opt-in (var.enable_container_insights) for cost; service CPU/memory metrics are still emitted.
  name = "${var.name_prefix}-cluster"
  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }
}

# --- IAM ---------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "PullImage"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
    resources = [aws_ecr_repository.app.arn]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken does not support resource-level permissions
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
  statement {
    sid       = "FaultTokenSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.fault_token_secret_arn]
  }
  statement {
    sid       = "DecryptSecretAndImage"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# The app itself calls no AWS APIs, so its task role has no permissions.
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# --- Task definition & service -------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name                   = local.container_name
    image                  = local.image
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment = [
      { name = "PORT", value = tostring(var.container_port) },
      { name = "APP_VERSION", value = var.image_tag },
    ]
    secrets = [{ name = "FAULT_TOKEN", valueFrom = var.fault_token_secret_arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_security_group" "alb" {
  # checkov:skip=CKV_AWS_260:Ingress CIDRs come from var.allowed_ingress_cidrs (validated non-empty; documented as your IP /32).
  name        = "${var.name_prefix}-alb"
  description = "Public HTTP to the demo ALB"
  vpc_id      = var.vpc_id
  ingress {
    description = "HTTP from allowed CIDRs"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }
  egress {
    description = "To tasks"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "ECS tasks: ingress only from the ALB"
  vpc_id      = var.vpc_id
  ingress {
    description     = "App port from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    # checkov:skip=CKV_AWS_382:Tasks need HTTPS egress to ECR/Logs/Secrets Manager (no NAT/VPC endpoints for cost).
    description = "HTTPS to AWS APIs (ECR, Logs, Secrets Manager)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "this" {
  # checkov:skip=CKV_AWS_150:Deletion protection off so the documented cleanup procedure can destroy the demo.
  # checkov:skip=CKV_AWS_91:ALB access logs are optional for the demo (cost); enable for production.
  # checkov:skip=CKV2_AWS_28:WAF is out of scope for the demo workload; listed in docs/security.md.
  # checkov:skip=CKV2_AWS_20:HTTP-only because the demo has no domain/ACM cert; see var.certificate_arn note.
  name                       = "${var.name_prefix}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = false # demo environment must be fully destroyable
}

resource "aws_lb_target_group" "app" {
  # checkov:skip=CKV_AWS_378:ALB->task traffic stays inside the VPC; TLS termination at the ALB is the production upgrade path.
  name                 = "${var.name_prefix}-tg"
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 10
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  # checkov:skip=CKV_AWS_2:HTTP-only demo listener (no domain/cert). Use HTTPS + ACM in production.
  # checkov:skip=CKV_AWS_103:See above.
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_ecs_service" "app" {
  # checkov:skip=CKV_AWS_333:No NAT gateway (cost); tasks need public IPs for ECR/Logs egress, SG blocks all non-ALB ingress.
  name                              = "${var.name_prefix}-app"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.app.arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 30
  enable_execute_command            = false

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true # no NAT gateway; SG blocks all ingress except the ALB
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # The remediation runbooks legitimately change desired count / task definition; don't fight them.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.http]
}
