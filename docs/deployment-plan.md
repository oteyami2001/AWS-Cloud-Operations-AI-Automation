# Deployment plan: bootstrap + Phases 1–2 (first AWS deployment)

> ⛔ **Nothing in this document has been executed.** Every command that creates AWS resources is
> marked 💲 and waits for the owner's explicit approval.

## Decisions (from the owner)

| # | Decision | Implementation |
|---|---|---|
| 1 | Region `us-east-1` | `region` default in bootstrap and envs/dev |
| 2 | ALB reachable only from the owner's public IP `/32` | `allowed_ingress_cidrs` (validated `/32`-only); **IP to be provided by the owner** |
| 3 | CloudWatch alert e-mails + AWS Budget notifications | `alert_email` (SNS) and `budget_email` (Budgets); **address to be confirmed by the owner** |
| 4 | Encrypted, versioned S3 remote state with locking, bootstrapped first | `terraform/bootstrap` (S3 + native lock file) |
| 5 | GitHub Actions OIDC + least-privilege roles, no access keys | plan / apply / image-push roles, permissions boundary |
| 6 | Bedrock disabled for the first deployment | `bedrock_enabled = false` (asserted by a test); no Bedrock IAM permission is created |
| 7 | PR to `main` after CI passes | see the PR |
| 8 | No AWS resources without explicit approval | this plan stops at each 💲 gate |

## What "Phases 1–2" provisions

Phase 1 is the monitored workload; Phase 2 is the alarms and EventBridge routing. Phase 2's
EventBridge rules need a target, so the `envs/dev` root deploys the analyzer, remediation and
dashboard resources in the **same apply** (Phases 3, 5 and 6, minus Bedrock). They add about
$0.10/day and make the incident pipeline usable as soon as the alarms exist.

### Step A: `terraform/bootstrap` (18 resources, long-lived)

| Service | Resources |
|---|---|
| S3 (state) | bucket `aiops-tfstate-<account>-us-east-1`, versioning, SSE-S3, Block Public Access, ownership controls (ACLs off), TLS-only bucket policy, lifecycle (7 resources) |
| IAM / OIDC | GitHub OIDC provider (skipped if one exists), roles `aiops-github-plan`, `aiops-github-apply`, `aiops-github-image-push` + 3 inline policies, permissions boundary `aiops-dev-workload-boundary` (8) |
| ECR | repository `aiops-sample-app` (immutable tags, scan on push) + lifecycle policy (2) |
| AWS Budgets | `aiops-account-monthly`, $30/month, 4 e-mail notifications (1) |

### Step B: `terraform/envs/dev` (80 resources, destroyable)

| Module (phase) | Count | Resources |
|---|---|---|
| security (1) | 4 | KMS key (rotation on) + alias; Secrets Manager secret + write-only version (fault token) |
| network (1) | 8 | VPC 10.40.0.0/16, 2 public subnets (2 AZs), internet gateway, route table + 2 associations, locked-down default SG |
| workload (1) | 12 | ECS cluster, Fargate task definition (image pinned by digest), ECS service (1 task, 0.25 vCPU / 0.5 GB), ALB + listener :80 + target group, 2 security groups, execution + task roles + policy, app log group |
| monitoring (2) | 11 | SNS topic (KMS) + policy, log metric filter, **8 alarms**: cpu-high, memory-high, alb-5xx, app-errors, unhealthy-targets, no-healthy-targets, platform-analyzer-errors, platform-dlq-not-empty. Plus 1 e-mail subscription if `alert_email` is set (81 total) |
| aiops (2–5) | 38 | 3 EventBridge rules + targets + Lambda permissions, SQS DLQ + policy, DynamoDB incidents table (KMS, PITR), 4 Lambdas (arm64) + log groups, IAM-auth Function URL, 6 IAM roles + 10 policies + 1 attachment (operator, senior approver) |
| remediation (5) | 6 | 4 SSM Automation documents, automation role + policy |
| dashboard (6) | 1 | CloudWatch dashboard |

Not created: NAT gateway, Container Insights, VPC flow logs, ALB access logs, WAF, Bedrock access
(all off by design; each is a variable).

## Cost estimate (us-east-1 on-demand list prices, verify with the AWS Pricing Calculator)

### While `envs/dev` is running

| Item | Unit price | Minimum billing | Per hour | Per day | Per month (730 h) |
|---|---|---|---|---|---|
| Application Load Balancer | $0.0225/h + LCU ($0.008/LCU-h, ≈0 at demo traffic) | **each started hour billed in full** | $0.0225 | $0.54 | $16.43 |
| Public IPv4 (2 on ALB + 1 on the task) | $0.005/IP-h | hourly | $0.015 | $0.36 | $10.95 |
| ECS Fargate 0.25 vCPU / 0.5 GB (Linux x86) | $0.04048/vCPU-h + $0.004445/GB-h | per second, **1-minute minimum** per task | $0.0123 | $0.30 | $9.01 |
| KMS customer-managed key | $1/key-month | prorated hourly | $0.0014 | $0.03 | $1.00 |
| Secrets Manager secret | $0.40/secret-month | prorated | $0.0005 | $0.01 | $0.40 |
| CloudWatch: 8 alarms, 1 dashboard, ~10 custom metrics, logs | $0.10/alarm-month, $3/dashboard-month, $0.30/metric-month, $0.50/GB ingested | prorated | ≈ $0.006 | ≈ $0.15 | ≈ $4.50 (often $0 within the always-free tier: 10 alarms, 3 dashboards, 10 metrics, 5 GB logs) |
| Lambda, DynamoDB on-demand, SQS, SNS, EventBridge (AWS events), SSM Automation, X-Ray | per request | — | ≈ 0 | < $0.02 | < $0.50 |
| **Total** | | | **≈ $0.058/h** | **≈ $1.30–1.40** | **≈ $38–43** |

**Typical demo session (deploy, run scenarios, capture evidence, destroy within 3 hours): ≈ $0.20–$0.35.**
Because ALB and public IPv4 bill per started hour, an apply plus an immediate destroy still costs about one hour (≈ $0.06).

### Persistent (bootstrap, after `envs/dev` is destroyed)

| Item | Expected cost |
|---|---|
| S3 state bucket (a few KB, versioned) | < $0.01/month |
| ECR repository (one ~50 MB image) | ≈ $0.005/month at $0.10/GB-month (or free-tier) |
| IAM roles, OIDC provider, permissions boundary | free |
| AWS Budget (1 budget, no actions) | expected $0 (within the free budget allowance; verify on the Budgets pricing page) |
| KMS key in `envs/dev` after destroy | scheduled for deletion with a 7-day waiting period (`deletion_window_in_days = 7`); at most ≈ $0.23 (prorated $1/month) if billed during the window - verify on the KMS pricing page |

### Bedrock (not enabled now)

$0. No Bedrock permission is created while `bedrock_enabled = false`.

## Prerequisites (owner)

1. **Answer the two open questions:** your public IPv4 address, and the e-mail address for alerts and budget.
2. An AWS identity with admin rights **through IAM Identity Center (SSO)**, used only for bootstrap. No access keys.
3. Local tools: AWS CLI v2, Terraform ≥ 1.11 (CI uses 1.17.2), Docker, Python 3.13.
4. GitHub:
   - Merge the PR to `main`. The plan and image roles trust `main` only.
   - Create the environment **`aws-dev`**: *Settings → Environments → New*. Add yourself as a **required reviewer**, and set *Deployment branches* to **Selected branches: `main`**.
   - Add a branch protection rule on `main` that requires the `ci` checks to pass.

## Commands

All commands run from the repository root. 💲 = creates or changes billable AWS resources (needs approval).

### 0. Confirm identity and region (read-only)

```bash
aws sso login --profile aiops-admin
```

```bash
export AWS_PROFILE=aiops-admin AWS_REGION=us-east-1
```

```bash
aws sts get-caller-identity
```

```bash
aws iam list-open-id-connect-providers
```

If the second command already lists `token.actions.githubusercontent.com`, set `create_oidc_provider = false` in the bootstrap tfvars.

### 1. 💲 Bootstrap: state, OIDC roles, boundary, ECR, budget

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
```

Edit `budget_email` in that file, then:

```bash
terraform -chdir=terraform/bootstrap init
```

```bash
terraform -chdir=terraform/bootstrap plan -out=bootstrap.tfplan
```

Review the plan (expect `18 to add` with `create_oidc_provider = true`), then:

```bash
terraform -chdir=terraform/bootstrap apply bootstrap.tfplan
```

Move the bootstrap state into the bucket it just created:

```bash
sed "s/aiops-tfstate-<account-id>-us-east-1/$(terraform -chdir=terraform/bootstrap output -raw state_bucket)/" terraform/bootstrap/backend.tf.example > terraform/bootstrap/backend.tf
```

```bash
terraform -chdir=terraform/bootstrap init -migrate-state
```

Accept the AWS Budgets confirmation if prompted. Then print the GitHub variables:

```bash
terraform -chdir=terraform/bootstrap output github_repository_variables
```

### 2. GitHub repository variables (no AWS cost)

*Settings → Secrets and variables → Actions → Variables*. Add `AWS_REGION`, `TF_STATE_BUCKET`,
`AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`, `AWS_IMAGE_PUSH_ROLE_ARN`, `ECR_REPOSITORY` (from the
output above), plus:

- `ALLOWED_INGRESS_CIDR` = `<your-ip>/32`
- `ALERT_EMAIL` = `<your e-mail>`

These are not secrets; the workflows use OIDC and no AWS keys are stored in GitHub.

### 3. 💲 Publish the image (ECR storage only, ≈ $0.005/month)

*Actions → image → Run workflow* on `main` with `image_tag = v1`. This builds the image, runs the
Trivy gate (fails on fixable HIGH/CRITICAL findings), pushes it, and prints the digest.

### 4. Plan (read-only role, no cost)

*Actions → deploy → Run workflow* on `main`: `action = plan`, `image_tag = v1`.
Read the job summary. Expect `Plan: 81 to add, 0 to change, 0 to destroy` (80 + the SNS e-mail subscription).

To plan locally instead, use the same state with your SSO credentials:

```bash
scripts/build_lambda.sh
```

```bash
cp terraform/envs/dev/backend.tf.example terraform/envs/dev/backend.tf
```

```bash
terraform -chdir=terraform/envs/dev init -backend-config="bucket=$(terraform -chdir=terraform/bootstrap output -raw state_bucket)"
```

```bash
terraform -chdir=terraform/envs/dev plan -var='allowed_ingress_cidrs=["<your-ip>/32"]' -var='alert_email=<your e-mail>' -out=tfplan
```

### 5. 💲 Deploy Phases 1–2 (≈ $0.058/hour from this point)

*Actions → deploy → Run workflow* on `main`: `action = apply`, `image_tag = v1`. The plan job runs
first; the **apply job then waits for your approval** in the `aws-dev` environment and applies
exactly the plan that was shown. Then confirm the SNS subscription e-mail.

### 6. Validate the deployment (read-only)

```bash
terraform -chdir=terraform/envs/dev output
```

```bash
curl -s "$(terraform -chdir=terraform/envs/dev output -raw app_url)/health"
```

Expected: `{"status": "ok"}`. From any other IP, the same request must time out:

```bash
aws ec2 describe-security-groups --filters Name=group-name,Values=aiops-dev-alb --query 'SecurityGroups[0].IpPermissions'
```

Expected: exactly one rule, tcp 80, your `/32`.

```bash
aws cloudwatch describe-alarms --alarm-name-prefix aiops-dev- --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
```

Expected: all `OK` after about 5 minutes. `no-healthy-targets` may briefly go to ALARM while the first task registers; the analyzer then opens and auto-resolves one incident.

```bash
aws ecs describe-services --cluster aiops-dev-cluster --services aiops-dev-app --query 'services[0].[status,runningCount,desiredCount,deployments[0].rolloutState]'
```

```bash
aws iam get-role --role-name aiops-dev-incident-analyzer-role --query 'Role.PermissionsBoundary'
```

```bash
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" --query 'Budgets[].[BudgetName,BudgetLimit.Amount]'
```

```bash
aws s3api get-bucket-versioning --bucket "$(terraform -chdir=terraform/bootstrap output -raw state_bucket)"
```

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=aiops --query 'length(ResourceTagMappingList)'
```

Capture the screenshots listed in `docs/evidence/README.md`, section C.

### 7. 💲 Cleanup (stops all hourly charges)

*Actions → deploy → Run workflow*: `action = destroy` → approve in `aws-dev`. Or locally:

```bash
terraform -chdir=terraform/envs/dev destroy -var='allowed_ingress_cidrs=["<your-ip>/32"]'
```

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=aiops Key=Environment,Values=dev --query 'ResourceTagMappingList[].ResourceARN'
```

Expected: empty, apart from the KMS key in `PendingDeletion`. Bootstrap stays in place (≈ $0/month).
Removing bootstrap as well is covered in `docs/cleanup.md`.

## Risks and rollback

| Risk | Mitigation |
|---|---|
| A CI role is missing an IAM action on the first run | The plan fails safely (read-only) or the apply stops part-way. Re-run after adding the action; a partial apply can be destroyed |
| Forgetting to destroy | AWS Budget e-mails at 50/80/100 %; cost is about $1.35/day |
| Image tag missing | The plan fails before anything is created (`data.aws_ecr_image`) |
| Ingress misconfigured | Validation rejects anything other than `/32` at plan time |
| State corruption | S3 versioning (≥ 20 versions kept); restore the previous object version |
