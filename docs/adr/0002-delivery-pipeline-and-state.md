# ADR 0002: Delivery pipeline, state and CI identity

- **Status:** Accepted (pre-deployment)
- **Date:** 2026-11-20

## Context

Before the first AWS deployment the owner asked for: S3 remote state with encryption, versioning
and locking; GitHub Actions OIDC with least-privilege roles and no long-lived keys; the ALB
restricted to one `/32`; alert and budget e-mails; Bedrock off; and no resources created without
explicit approval.

## Decisions

| # | Decision | Alternatives | Why |
|---|---|---|---|
| 1 | **S3-native state locking** (`use_lockfile`, Terraform ≥ 1.10) | DynamoDB lock table | HashiCorp's current recommendation (DynamoDB locking is deprecated); one fewer resource |
| 2 | **SSE-S3** on the state bucket | SSE-KMS with a CMK | State holds no secrets after decision 3. Avoids a persistent $1/month key. Versioning, TLS-only and Block Public Access still apply |
| 3 | **Ephemeral + write-only secret** for the fault token (`aws_secretsmanager_random_password`, `secret_string_wo`) | `random_password` + `secret_string` | Keeps the secret out of state and plan files |
| 4 | **Bootstrap holds the long-lived pieces**: state, OIDC roles, permissions boundary, ECR, budget | Everything in `envs/dev` | `destroy` of the environment never removes CI access, state, images or the cost guardrail |
| 5 | **Three CI roles** (plan / apply / image-push) with exact `sub` matching; apply only from the reviewer-gated `aws-dev` environment | One deploy role; `repo:*` wildcard | Separation of duties. A reviewer approves the exact saved plan that is applied |
| 6 | **Apply role scoped by service + region**, IAM writes only with a **mandatory permissions boundary** | `PowerUserAccess` + IAM | Blocks the "create an admin role and assume it" escalation. Resource-level scoping of `Create*` is not possible for most services; tighten later from CloudTrail with IAM Access Analyzer |
| 7 | **Image published separately and pinned by digest**; the plan fails if the tag is missing | Build inside the apply job | Avoids a first deployment whose tasks can't pull an image. The reviewed plan references an immutable digest |
| 8 | **Account-wide budget** | Tag-filtered budget | A tag filter reads $0 until the cost-allocation tag is activated (up to 24 h), so it could not alert |
| 9 | **All GitHub Actions pinned to commit SHAs** | Version tags | Tags are mutable and have been hijacked in real supply-chain attacks |

## Consequences

- One manual, human step remains: applying bootstrap with SSO admin credentials.
- The `deploy` and `image` workflows run only from `main`, so changes reach AWS only after review and merge.
- The IAM policies have only been checked statically. The first real plan/apply may reveal a missing read action, which will be fixed in a follow-up.
