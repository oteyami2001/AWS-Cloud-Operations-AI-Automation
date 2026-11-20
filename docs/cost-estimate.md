# Cost estimate (us-east-1)

> **Estimates only**, based on public on-demand list prices as of late 2026. Verify with the
> [AWS Pricing Calculator](https://calculator.aws/) before deploying. Nothing in this repository
> deploys billable resources automatically: `deploy.yml` is manual and gated by a GitHub
> environment approval, and local commands only run when you type them.

## Running cost while the demo environment exists

| Resource | Sizing | ≈ per day | ≈ per month |
|---|---|---|---|
| Application Load Balancer | 1 ALB, minimal LCUs | $0.55 | $16.50 |
| Public IPv4 addresses | 2 (ALB) + 1 (task) × $0.005/h | $0.36 | $11.00 |
| ECS Fargate | 1 task, 0.25 vCPU / 0.5 GB | $0.30 | $9.00 |
| CloudWatch | 8 alarms, 1 dashboard, logs (14-day retention) | $0.15 | $4.50 |
| KMS | 1 customer-managed key | $0.03 | $1.00 |
| Secrets Manager | 1 secret | $0.01 | $0.40 |
| DynamoDB, Lambda, SQS, SNS, EventBridge, SSM Automation | on-demand, demo volume | < $0.05 | < $1.00 |
| ECR | < 1 GB images | < $0.01 | $0.10 |
| **Total (Bedrock off)** | | **≈ $1.45 / day** | **≈ $43 / month** |

**Recommended usage:** deploy, run the demo scenarios and capture evidence in one 2-4 hour
session, then `terraform destroy` → **≈ $0.25-$0.50 per demo session**.

## Amazon Bedrock (optional, Phase 4)

- One model call per **new** incident only (repeat alarms are deduplicated, not re-analysed).
- Input ≈ 3-5K tokens (evidence capped at 12K characters), output ≈ 0.5-1K tokens.
- Hard daily cap: `bedrock_daily_call_limit` (default 20), enforced atomically in DynamoDB;
  beyond it the rules engine is used. Reserved concurrency (5) bounds alarm storms.
- Price depends on the model and Bedrock's pricing page; at Opus-class prices a demo session with
  ~10 incidents costs well under $1. Switch `bedrock_model_id` to a smaller model to reduce cost.

## Cost controls built in

- `aws_budgets_budget` with 50% forecast / 100% actual e-mail alerts (`budget_email`).
- Default tags (`Project`, `Environment`, `Owner`, `CostCenter`) on every resource → activate the
  `Project` cost-allocation tag in Billing to see this project in Cost Explorer.
- No NAT gateway (saves ≈ $33/month + data processing), no Container Insights / flow logs / ALB access
  logs by default (each is a variable).
- 14-day log retention, ECR lifecycle (keep 10 images), on-demand DynamoDB.
- Remediation runbooks cap desired count with `allowedValues` (max 4 tasks).
- `docs/cleanup.md` removes everything, including ECR images and the secret (no recovery window).
