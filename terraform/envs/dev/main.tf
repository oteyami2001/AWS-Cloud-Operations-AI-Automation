# dev environment: composes every module into the full platform.
data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  # Deterministic names break the monitoring <-> aiops dependency cycle.
  analyzer_function_name = "${local.name_prefix}-incident-analyzer"
  dashboard_url          = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${local.name_prefix}-operations"
}

module "security" {
  source      = "../../modules/security"
  name_prefix = local.name_prefix
}

module "network" {
  source           = "../../modules/network"
  name_prefix      = local.name_prefix
  cidr_block       = var.vpc_cidr
  enable_flow_logs = var.enable_flow_logs
  kms_key_arn      = module.security.kms_key_arn
}

module "workload" {
  source                    = "../../modules/workload"
  name_prefix               = local.name_prefix
  vpc_id                    = module.network.vpc_id
  vpc_cidr                  = var.vpc_cidr
  public_subnet_ids         = module.network.public_subnet_ids
  kms_key_arn               = module.security.kms_key_arn
  fault_token_secret_arn    = module.security.fault_token_secret_arn
  container_image           = var.container_image
  image_tag                 = var.image_tag
  desired_count             = var.baseline_desired_count
  allowed_ingress_cidrs     = var.allowed_ingress_cidrs
  enable_container_insights = var.enable_container_insights
}

module "monitoring" {
  source                  = "../../modules/monitoring"
  name_prefix             = local.name_prefix
  account_id              = data.aws_caller_identity.current.account_id
  kms_key_arn             = module.security.kms_key_arn
  cluster_name            = module.workload.cluster_name
  service_name            = module.workload.service_name
  alb_arn_suffix          = module.workload.alb_arn_suffix
  target_group_arn_suffix = module.workload.target_group_arn_suffix
  app_log_group_name      = module.workload.app_log_group_name
  analyzer_function_name  = local.analyzer_function_name
  dlq_name                = "${local.name_prefix}-events-dlq"
  alert_email             = var.alert_email
  budget_email            = var.budget_email
  monthly_budget_usd      = var.monthly_budget_usd
  project_tag             = var.project
}

module "remediation" {
  source      = "../../modules/remediation"
  name_prefix = local.name_prefix
  service_arn = module.workload.service_arn
}

module "aiops" {
  source                   = "../../modules/aiops"
  name_prefix              = local.name_prefix
  kms_key_arn              = module.security.kms_key_arn
  lambda_package_path      = var.lambda_package_path
  alerts_topic_arn         = module.monitoring.alerts_topic_arn
  cluster_name             = module.workload.cluster_name
  cluster_arn              = module.workload.cluster_arn
  service_name             = module.workload.service_name
  service_arn              = module.workload.service_arn
  target_group_arn         = module.workload.target_group_arn
  app_log_group_name       = module.workload.app_log_group_name
  app_log_group_arn        = module.workload.app_log_group_arn
  workload_alarm_arns      = module.monitoring.alarm_arns
  automation_role_arn      = module.remediation.automation_role_arn
  runbook_document_names   = module.remediation.document_names
  baseline_desired_count   = var.baseline_desired_count
  max_desired_count        = var.max_desired_count
  bedrock_enabled          = var.bedrock_enabled
  bedrock_model_id         = var.bedrock_model_id
  bedrock_daily_call_limit = var.bedrock_daily_call_limit
  trusted_principal_arns   = length(var.trusted_principal_arns) > 0 ? var.trusted_principal_arns : ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
  require_mfa              = var.require_mfa
  dashboard_url            = local.dashboard_url
}

module "dashboard" {
  source                  = "../../modules/dashboard"
  name_prefix             = local.name_prefix
  dashboard_function_arn  = module.aiops.dashboard_function_arn
  function_names          = values(module.aiops.function_names)
  cluster_name            = module.workload.cluster_name
  service_name            = module.workload.service_name
  alb_arn_suffix          = module.workload.alb_arn_suffix
  target_group_arn_suffix = module.workload.target_group_arn_suffix
  app_log_group_name      = module.workload.app_log_group_name
  alarm_arns              = module.monitoring.alarm_arns
}
