# Sample-app image repository. Lives in bootstrap so images are built and scanned BEFORE an
# environment is planned (envs/dev fails at plan time if the image tag does not exist).
resource "aws_ecr_repository" "app" {
  # checkov:skip=CKV_AWS_136:AES-256 encryption at rest; a KMS key here would add a persistent $1/month charge.
  name                 = "${var.project}-sample-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # lets the cleanup procedure remove the repository with its images
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
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

# Account-level cost guardrail. Account-wide (not tag-filtered) so it works immediately - a
# Project cost-allocation tag filter would read $0 until the tag is activated in Billing (up to 24 h).
# Budgets data refreshes several times a day, so alerts can lag actual spend by hours.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-account-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", threshold = 50 },
      { type = "ACTUAL", threshold = 80 },
      { type = "ACTUAL", threshold = 100 },
      { type = "FORECASTED", threshold = 100 },
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.budget_email]
    }
  }
}
