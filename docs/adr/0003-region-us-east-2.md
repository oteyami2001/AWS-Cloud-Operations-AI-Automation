# ADR 0003: Deploy to us-east-2 (Ohio) because the organization's SCP denies us-east-1

- **Status:** Accepted (approved by the owner, 2026-11-22). Supersedes the region choice in the deployment plan (decision 1, previously us-east-1).
- **Date:** 2026-11-22

## Context

The first bootstrap apply in account `666102401492` created 6 global resources (the GitHub OIDC
provider, 3 CI roles, the permissions boundary and the budget), then failed on the regional ones:

```
not authorized to perform: s3:CreateBucket on resource: "arn:aws:s3:::aiops-tfstate-666102401492-us-east-1"
with an explicit deny in a service control policy:
arn:aws:organizations::230372368776:policy/o-fnvel86t82/service_control_policy/p-gcytj9gj
```

The account belongs to AWS Organization `o-fnvel86t82` (management account `230372368776`). An SCP
cannot be overridden from inside a member account. Read-only tests by the owner:

| Check | us-east-1 | us-east-2 |
|---|---|---|
| `ecr:DescribeRepositories`, `ec2:DescribeVpcs`, `ecs:ListClusters` | **explicit deny (SCP)** | allowed |
| S3, ELBv2, Lambda, DynamoDB, CloudWatch Logs, KMS, Secrets Manager, SSM, SQS, SNS, EventBridge, CloudWatch, X-Ray (list/describe) | n/a | allowed |
| Console bucket creation | n/a | allowed (`project-demo-thierry-oteyami-bucket01`, a test bucket outside this project) |
| IAM, AWS Budgets (global) | allowed | allowed |

## Decision

Deploy everything regional to **us-east-2**. The region stays a variable (`region`), so the project
can move back if the SCP changes.

## Consequences

- Nothing already created is affected: the 6 existing resources are global (IAM, Budgets), so the
  resume plan stays "12 to add, 0 to change, 0 to destroy".
- State bucket: `aiops-tfstate-666102401492-us-east-2`. Backend examples, the resume script and the
  GitHub variable `AWS_REGION` use us-east-2.
- The CI apply role's `aws:RequestedRegion` condition follows `var.region`, so it is us-east-2 only.
  IAM and Budgets calls are in separate statements and are unaffected.
- Cost: on-demand prices for these services are the same as in us-east-1.
- Phase 4 (Bedrock): confirm which Claude models Bedrock offers in us-east-2 before enabling it.
- Not tested: whether the SCP also restricts specific *write* actions in us-east-2. The read-only
  checks passed; the gated apply surfaces any remaining deny without destroying anything.
