# Pre-deployment security review (Phases 1–2)

Date: 2026-11-20 · Scope: `terraform/bootstrap`, `terraform/envs/dev` and all modules, CI/CD workflows.
**Nothing has been deployed to AWS.** All results below come from static analysis and offline tests
with mocked providers.

## 1. Why CI failed and what changed

The first `ci` run ([run 44768830198](https://github.com/oteyami2001/AWS-Cloud-Operations-AI-Automation/actions/runs/44768830198))
**did run**. 2 of 4 jobs failed, both because of the workflow configuration, not the code:

| Job | Root cause | Fix |
|---|---|---|
| Terraform | `tflint --init` called the GitHub API without a token and hit the shared-runner rate limit (HTTP 403) | Pass `GITHUB_TOKEN` to the tflint step; ruleset updated 0.34.0 → 0.50.0 |
| Container | `aquasecurity/trivy-action@0.28.0` no longer exists (the action now only publishes `v`-prefixed tags) | Pinned `aquasecurity/trivy-action` to the **commit SHA** of `v0.36.0` |
| (all) | Actions referenced by mutable tags; Node 20 deprecation warnings | **Every** action pinned to a full commit SHA on its current major; `persist-credentials: false` on checkout |

Other hardening done in this pass:

- **Terraform 1.9.8 → 1.17.2, AWS provider 5.80 → 5.100.** This enables two things:
  - S3-native state locking (`use_lockfile`), so the DynamoDB lock table is gone.
  - Write-only secret arguments: the fault-injection token is now generated as an **ephemeral** value (`aws_secretsmanager_random_password`) and written with `secret_string_wo`, so it is **never stored in Terraform state or plan files**. The `random` provider was removed.
- **ECR moved to bootstrap, and the image is pinned by digest.** `envs/dev` reads the image with a data source, so `terraform plan` **fails before creating anything** if the tag has not been pushed. The task definition references `repo@sha256:…`.
- **Least-privilege CI roles replace `ReadOnlyAccess` / `PowerUserAccess`**, plus a mandatory permissions boundary (section 4).
- **The budget moved to bootstrap and is now account-wide.** The previous tag-filtered budget would have read $0 until the `Project` cost-allocation tag was activated, so it could never alert.
- **Ingress is validated as `/32` only**, enforced at both the root and the module level (section 3).

## 2. Validation results (local, 2026-11-20)

Full log: [`evidence/local/validation-run.txt`](evidence/local/validation-run.txt)

| Check | Tool | Result |
|---|---|---|
| Python lint / format | ruff 0.13 | ✅ pass |
| Python SAST | bandit 1.8 | ✅ 0 issues |
| Unit + integration tests | pytest + moto | ✅ 60 passed, 92.9 % coverage (gate 85 %) |
| Terraform format | `terraform fmt -check` 1.17.2 | ✅ |
| Terraform validate | bootstrap, envs/dev, modules | ✅ 4/4 roots valid |
| Terraform offline tests | `terraform test` with mocked providers | ✅ **25/25** (bootstrap 6, envs/dev 7, aiops 7, workload 5) |
| Terraform lint | tflint 0.59.1 + AWS ruleset 0.50.0 | ✅ 0 issues (10 directories) |
| IaC security | Checkov 3.4.6 | ✅ 406 passed, **0 failed**, 38 skipped (all justified inline, reviewed below) |
| IaC + Dockerfile misconfig | Trivy 0.76.2 `config` | ✅ 0 HIGH/CRITICAL (5 justified inline ignores) |
| Dependencies + secrets | Trivy `fs` | ✅ 0 HIGH/CRITICAL |
| Docker build, read-only/non-root smoke test, image CVE scan | Docker + Trivy (CI) | ✅ passed in CI after the image hardening. The first gated run correctly **blocked** base-image CVEs: `zlib1g` CVE-2026-85091 and HIGH findings in pip-vendored `msgpack`/`urllib3`/`setuptools`, fixed by OS patching and removing pip |
| Full CI on GitHub (4 jobs: Python, Terraform + tflint, Checkov + SARIF, Container + Trivy) | GitHub Actions | ✅ [run 44829246081](https://github.com/oteyami2001/AWS-Cloud-Operations-AI-Automation/actions/runs/44829246081) (`pull_request`) and [run 44829201157](https://github.com/oteyami2001/AWS-Cloud-Operations-AI-Automation/actions/runs/44829201157) (`push`), both green |

## 3. Network exposure verification

| Surface | Exposure | Enforcement | Test |
|---|---|---|---|
| ALB listener tcp/80 | **Only your /32** | `allowed_ingress_cidrs` must be non-empty, valid IPv4 and **every entry `/32`**. `0.0.0.0/0`, `/24` and malformed values fail validation | `envs/dev`: `ingress_rejects_open_internet`, `…wider_than_32`, `…malformed_address`, `…must_be_explicit`; `workload`: `alb_ingress_is_exactly_the_operator_ip_on_port_80` (exactly 1 rule, tcp/80, that /32 only, no IPv6 / SG / prefix-list sources) |
| ECS tasks :8080 | ALB security group only | Task SG ingress references the ALB SG and has no CIDR rules | `tasks_accept_traffic_only_from_the_alb` |
| Task egress | tcp/443 to AWS APIs | HTTPS only (no NAT for cost) | same test |
| Default VPC SG | none | `aws_default_security_group` with no rules | Checkov CKV2_AWS_12 pass |
| ECS Exec | disabled | `enable_execute_command = false` | `no_public_admin_surfaces` |
| Remediation Function URL | Internet-reachable **but IAM-authenticated** (SigV4) | `authorization_type = AWS_IAM`, operator role required, MFA by default | `approval_endpoint_requires_iam_auth`, `human_roles_require_mfa_by_default` |
| State bucket | private | Block Public Access ×4, ACLs disabled, TLS-only bucket policy | `state_bucket_is_private_versioned_encrypted` |
| ECR repository | private | no repository policy (account-only) | — |

**Result: no unintended public ingress.** The ALB is the only network listener, and only your `/32`
can reach it. The approval endpoint is reachable from the internet, but every request is rejected
unless it is SigV4-signed by the operator role.

## 4. Identity, OIDC and state review

| Item | Configuration | Verdict |
|---|---|---|
| GitHub OIDC provider | `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`. `create_oidc_provider=false` if the account already has one | ✅ |
| Plan role trust | `StringEquals` on `sub` = `repo:oteyami2001/AWS-Cloud-Operations-AI-Automation:ref:refs/heads/main` or `…:pull_request`. Audience pinned | ✅ exact match, no wildcards (tested) |
| Apply role trust | `sub` = `…:environment:aws-dev` **only** | ✅ but **depends on you** configuring the `aws-dev` environment with a required reviewer and deployment branch `main` |
| Image-push role trust | `…:ref:refs/heads/main` only; ECR push to the one repository | ✅ |
| Plan role permissions | Describe/List/Get metadata for the services in use. **No** S3 object reads outside state, DynamoDB items, log events, SQS messages, SSM parameters, image layers, or KMS decrypt. One exception: `GetSecretValue` on the demo fault token, needed to refresh the secret version | ✅ (tested) |
| Apply role permissions | Listed services only, limited to `us-east-1` (`aws:RequestedRegion`); EC2 limited to VPC/SG/route APIs (it **cannot** launch instances). IAM writes only on `aiops-dev-*` roles **and only when the workload permissions boundary is attached**. Explicit denies: removing boundaries, IAM users/access keys, Organizations/account, CloudTrail stop/delete, state-bucket policy/versioning changes, any change to the CI roles or the boundary | ✅ blocks the classic "create an admin role" escalation (tested) |
| Workload permissions boundary | All 9 workload roles carry it (10 with VPC flow logs on). It is a ceiling: only the actions those roles use, IAM writes denied, PassRole only for `aiops-dev-*` | ✅ |
| State storage | S3, SSE-S3 (AES-256), versioning, 90-day non-current expiry (keeps ≥20 versions), TLS-only, Block Public Access, ACLs disabled, denies unencrypted puts | ✅ |
| State locking | S3-native lock file (`use_lockfile = true`, `-lock-timeout=5m` in CI, one deploy at a time via workflow concurrency) | ✅ |
| Secrets in state | None. The fault token is ephemeral/write-only | ✅ |
| Budget | Account-wide, $30/month (variable), e-mail at 50 % / 80 % / 100 % actual and 100 % forecast; lives in bootstrap so it exists **before** deployment and survives `destroy` | ✅ (needs your e-mail). AWS Budgets refreshes a few times a day, so alerts lag spend by hours. It is a guardrail, not a hard stop |
| CloudWatch alert e-mail | SNS subscription in `envs/dev` (`alert_email`); AWS sends a confirmation e-mail you must accept | ✅ (needs your e-mail) |

**Residual IAM caveats (honest):**

- Apply-role write permissions are scoped by **service and region**, not by resource ARN, because
  `Create*` APIs mostly cannot be resource-scoped. Recommended follow-up after the first deployment:
  generate a tighter policy from the actual CloudTrail calls with IAM Access Analyzer.
- These IAM policies have only been checked statically. The first real `plan`/`apply` may still
  surface a missing read action (for example a new provider refresh call). If so, add it and record it here.
- Bootstrap itself must be applied by a human with admin rights. Use **IAM Identity Center (SSO)
  short-lived credentials**, not access keys.

## 5. Review of the 38 Checkov skips

Risk = residual risk **for this demo deployment** (one account, ALB limited to your /32, no customer data).

| Checks | Check(s) | Resource | Why skipped | Residual risk |
|---|---|---|---|---|
| 1–2 | CKV_AWS_2, CKV_AWS_103 | ALB listener | HTTP only: no domain / ACM certificate | 🟠 **MEDIUM - material.** The fault-injection header `X-Fault-Token` and all demo traffic cross the internet **unencrypted**. Anyone on the network path (e.g. public Wi-Fi) could read the token and toggle demo faults. Impact is limited to this demo app (no data, no AWS credentials). **Mitigations:** run demos from a trusted network; rotate the token (`fault_token_version`) after a demo; production fix = ACM certificate + HTTPS listener + HTTP→HTTPS redirect (needs a domain). |
| 3 | CKV_AWS_378 | Target group HTTP | ALB→task traffic stays in the VPC | 🟢 Low |
| 4 | CKV2_AWS_20 | ALB HTTP→HTTPS redirect | Same root cause as checks 1–2 | (covered by rows 1–2) |
| 5 | CKV2_AWS_28 | ALB without WAF | Cost/scope; ingress already /32 | 🟢 Low (only your IP can reach it) |
| 6 | CKV_AWS_91 | ALB access logs off | Cost | 🟡 Low-Medium: no request-level forensics; turn on for real incidents |
| 7 | CKV_AWS_150 | ALB deletion protection off | Must be destroyable | 🟢 Low |
| 8 | CKV_AWS_260 | ALB SG port 80 | CIDRs come from a variable (Checkov can't see the /32 validation) | 🟢 Low: validated /32 + tested |
| 9 | CKV_AWS_130 | Public subnets | No NAT gateway (saves ≈ $33/month) | 🟢 Low |
| 10 | CKV_AWS_333 | Task public IP | Same as check 9; SG admits only the ALB | 🟢 Low |
| 11 | CKV_AWS_382 | Task egress 443 to 0.0.0.0/0 | Needs ECR/Logs/Secrets Manager without endpoints | 🟡 Low-Medium: a compromised container could send data out over HTTPS. The container holds no data and its role has no permissions |
| 12 | CKV_AWS_65 | Container Insights off | Cost; service CPU/memory metrics still emitted | 🟢 Low |
| 13–14 | CKV_AWS_338 ×2 | 14-day log retention | Cost | 🟢 Low for the demo; production ≥ 1 year |
| 15 | CKV_AWS_394 | AZ data source | Only the first 2 AZs are used | 🟢 None |
| 16 | CKV_AWS_117 | Lambdas not in a VPC | They call public AWS APIs only | 🟢 Low |
| 17 | CKV_AWS_272 | No Lambda code signing | Artifact hash pinned via `source_code_hash` | 🟡 Low-Medium: whoever can push to `main` and pass review can change the Lambda code. Mitigated by branch protection + environment approval |
| 18 | CKV2_AWS_57 | Secret without rotation | Demo switch; rotate via `fault_token_version` | 🟢 Low |
| 19–21 | CKV_AWS_109/111/356 | KMS key policy | Standard root-admin key policy, real use scoped by IAM | 🟢 None (AWS-recommended pattern) |
| 22–23 | CKV_AWS_356 ×2 | Operator / senior-approver policies | `ssm:DescribeAutomationExecutions` has no resource-level support | 🟢 None (read-only) |
| 24–27 | CKV_AWS_144, CKV_AWS_18, CKV2_AWS_62, CKV_AWS_145 | State bucket | No replication, no access logs, no notifications; SSE-S3 instead of KMS | 🟢 Low: state no longer contains secrets; versioning and TLS-only apply. Optional upgrade: SSE-KMS (+$1/month) |
| 28 | CKV_AWS_136 | ECR AES-256 (not KMS) | Avoids a persistent $1/month key | 🟢 Low |
| 29–31 | CKV_AWS_109/111/356 | Apply-role policy | `Create*` APIs can't be resource-scoped, so it is limited by service + region + boundary | 🟡 Low-Medium (see section 4 caveats). The role is only usable from the reviewer-gated environment |
| 32 | CKV_AWS_356 | Plan-role policy | Plan must refresh every resource type; metadata only | 🟢 Low (data reads excluded, tested) |
| 33–38 | CKV_AWS_107/108/109/110/111/356 | Workload permissions boundary | A boundary is a ceiling and must use `Resource "*"` | 🟢 None: it only ever **reduces** permissions |

**Material items:** only **checks 1–2, the plaintext HTTP listener**. It is accepted for this demo with the
mitigations listed. Checks 6, 11, 17 and 29–31 are low-medium and are listed as production follow-ups.
