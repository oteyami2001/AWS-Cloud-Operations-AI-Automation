# ADR 0001 - Event-driven AIOps platform with human-gated remediation

- **Status:** Accepted (implementation complete locally; AWS deployment pending owner approval)
- **Date:** 2026-11-20
- **Deciders:** Platform engineering (portfolio project)

## Context

Engineers lose time triaging failed deployments, unhealthy services and cost surprises. We want a
platform that detects issues, collects evidence, explains probable causes with AI, and proposes
safe remediation - **without** letting AI make unrestricted production changes.

Constraints: low cost (personal AWS account), fully destroyable, least privilege, testable without
an AWS account, and demonstrable end to end with a deliberately broken workload.

## Decisions

| # | Decision | Alternatives considered | Why |
|---|---|---|---|
| 1 | **CloudWatch alarms → EventBridge → Lambda** for detection and routing | Alarm → SNS → Lambda; polling | Native, push-based, per-rule DLQ/retry, filters on exact alarm ARNs. Alarm OK transitions drive auto-resolution. |
| 2 | **ECS Fargate + ALB** sample workload | EC2 ASG; Lambda workload | Realistic "unhealthy targets" and "task stopped" failure modes; no instances to patch. |
| 3 | **Deterministic severity + rules engine; Bedrock only for explanation** | Let the model decide severity/action | Paging/escalation must be predictable and testable. The model adds value in summarising evidence, not in policy decisions. |
| 4 | **Model output constrained by JSON schema with an enum of approved runbook ids**, re-validated in code | Free text parsed with regex | Makes "the model recommends something unapproved" structurally impossible; malformed / refused / failed calls degrade to the rules engine. |
| 5 | **Claude on Amazon Bedrock via the Anthropic SDK (`AnthropicBedrockMantle`)**, default `anthropic.claude-opus-5-5`, effort `medium`, opt-in flag | boto3 Converse API | Official SDK with structured outputs; model id is a variable. Bedrock is **off by default** (cost + model-access approval). |
| 6 | **Remediation via SSM Automation documents** from an allowlist of 4 | Lambda calling ECS directly; Step Functions | SSM gives audit trail, native `aws:approve` for second approval, bounded parameters (`allowedPattern` / `allowedValues`), and a scoped assume role. |
| 7 | **Human approval through an IAM-authenticated Lambda Function URL** (SigV4) | API Gateway + Cognito; Slack bot | Smallest secure surface: no public anonymous endpoint, approver identity comes from IAM (verified caller ARN), works from the CLI. |
| 8 | **Two-person rule for HIGH risk** (rollback) using `aws:approve` with a separate senior-approver role | Single approval for all | Separation of duties for the riskiest change, enforced by AWS, not by our code. |
| 9 | **DynamoDB** for incident records (on-demand, KMS, PITR) | RDS; OpenSearch | Pennies at this scale, serverless, GSIs for dedupe and execution lookups. |
| 10 | **CloudWatch dashboard with a Lambda custom widget** for the incident table | Public web app (S3/CloudFront) | Inherits AWS console auth - no new public surface, no front-end hosting. |
| 11 | **No NAT gateway; tasks in public subnets with SG ingress only from the ALB** | Private subnets + NAT / VPC endpoints | Saves ~$33+/month. Documented trade-off; production upgrade path is private subnets + endpoints. |
| 12 | **Terraform modules + offline `terraform test` with mocked providers**; GitHub Actions with OIDC, plan/apply split, environment approval | Terragrunt; CDK | Guardrails (e.g. "analyzer cannot start SSM") are asserted in CI without AWS credentials; no long-lived keys. |

## Consequences

- AI is advisory only. Every change requires a named human; HIGH risk requires two.
- The platform still works if Bedrock is unavailable, throttled, over quota, or refuses.
- Some checkov findings are accepted for cost/demo reasons; each is skipped inline with a
  justification and listed in `docs/security.md`.
- HTTP-only ALB (no domain/certificate in a personal account) - acceptable for a demo restricted to
  the owner's IP, called out as a production gap.
- Bedrock IAM action names for the Mantle endpoint must be verified at deploy time
  (`bedrock_iam_actions` variable) - see `docs/implementation-plan.md` Phase 4.
