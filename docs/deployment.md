# Deployment guide

> ⚠️ These steps create **billable** AWS resources (≈ $1.45/day, see `cost-estimate.md`).
> Run them only when you intend to, and follow `cleanup.md` afterwards.

## Prerequisites

| Tool | Version | Check |
|---|---|---|
| AWS account + admin-capable IAM identity (with MFA) | - | `aws sts get-caller-identity` |
| AWS CLI | v2 | `aws --version` |
| Terraform | ≥ 1.7 (CI uses 1.9.8) | `terraform version` |
| Python | 3.13 (3.12+ works locally) | `python3 --version` |
| Docker | any recent | `docker version` |
| (Phase 4) Bedrock model access for the chosen Claude model | - | Bedrock console → Model access |

```bash
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt
```

```bash
make test
```

## 1. (Optional) bootstrap remote state + CI roles

```bash
terraform -chdir=terraform/bootstrap init
```

```bash
terraform -chdir=terraform/bootstrap apply
```

Then copy `terraform/envs/dev/backend.tf.example` to `backend.tf` and fill in the bucket name from
the output. Skip this step to use local state for a single-person demo.

## 2. Configure

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
```

Edit `allowed_ingress_cidrs` (your IP `/32`), and optionally `alert_email` / `budget_email`.

## 3. Build the Lambda package

```bash
scripts/build_lambda.sh
```

## 4. Create the ECR repository, push the image, deploy everything

```bash
terraform -chdir=terraform/envs/dev init
```

```bash
terraform -chdir=terraform/envs/dev apply -target=module.workload.aws_ecr_repository.app
```

```bash
make push-image
```

```bash
terraform -chdir=terraform/envs/dev plan -out=tfplan
```

Review the plan, then:

```bash
terraform -chdir=terraform/envs/dev apply tfplan
```

## 5. Verify

```bash
curl -s "$(terraform -chdir=terraform/envs/dev output -raw app_url)/health"
```

```bash
scripts/simulate_incident.sh status
```

Open `terraform -chdir=terraform/envs/dev output -raw dashboard_url` in the console. Confirm the SNS
e-mail subscription if you set `alert_email`.

## 6. Operator access

Create a CLI profile that assumes the operator role with MFA (`~/.aws/config`):

```ini
[profile aiops-operator]
role_arn = <terraform output operator_role_arn>
source_profile = default
mfa_serial = arn:aws:iam::<account-id>:mfa/<your-device>
```

```bash
AWS_PROFILE=aiops-operator python scripts/approve.py --incident <INC-id> --show
```

Do the same for `aiops-senior-approver` (second approvals of HIGH-risk runbooks).

## 7. Enable Bedrock (Phase 4)

Enable model access in the Bedrock console, set `bedrock_enabled = true` in `terraform.tfvars`,
then plan and apply again. See the IAM verification note in `implementation-plan.md`.

## CI/CD (GitHub Actions)

- `ci.yml` runs on every push/PR with no AWS access: ruff, bandit, pytest (+coverage gate), offline
  incident simulation, terraform fmt/validate/test, tflint, checkov, container build + Trivy.
- `deploy.yml` is **manual** (`workflow_dispatch`): `plan` uses the read-only OIDC role; `apply` /
  `destroy` run only in the `aws-dev` environment, which you configure with required reviewers.
  Repository variables: `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`,
  `ALLOWED_INGRESS_CIDR`.
