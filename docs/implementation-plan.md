# Phased implementation plan

Status legend: ✅ **Done locally** (code + automated tests, no AWS) · ⏸️ **Awaiting your approval to
deploy** (billable) · 📋 **Planned**.

Nothing has been deployed to AWS. Each ⏸️ phase starts only after you confirm.

| Phase | Scope | Local status | AWS status | Exit criteria |
|---|---|---|---|---|
| 0 | ADR, architecture, repo structure, prerequisites, cost & security estimates | ✅ | n/a | Docs reviewed |
| 1 | Monitored sample workload (VPC, ECS Fargate, ALB, ECR, KMS, secret) | ✅ `terraform validate` + mocked `terraform test` | ⏸️ | `curl $APP_URL/health` → 200 |
| 2 | Alarms (CPU, memory, 5xx, app errors, unhealthy / no healthy targets) + EventBridge routing + DLQ | ✅ | ⏸️ | Alarms in `OK`; rules show invocations |
| 3 | Incident analyzer (evidence, dedupe, severity, rules engine, DynamoDB, SNS) | ✅ 60 unit/integration tests | ⏸️ | Scenario B creates and auto-resolves an incident |
| 4 | Bedrock-assisted root cause summaries (opt-in) | ✅ tested with a fake client | ⏸️ needs Bedrock model access | Incident `engine = bedrock:…`; fallback proven by disabling access |
| 5 | Human-approved remediation (4 SSM runbooks, approval Function URL, 2-person rule) | ✅ | ⏸️ | Scenario A restored via approved runbook; Scenario C waits at `aws:approve` |
| 6 | Operations dashboard (custom widget + metrics) | ✅ render tested | ⏸️ | Dashboard screenshot shows incident table |
| 7 | Automated testing + CI/CD (GitHub Actions, OIDC, plan/apply split) | ✅ workflows written; runs on push | ⏸️ OIDC bootstrap | Green `ci` run; `deploy` plan run |
| 8 | Observability of the platform itself (EMF metrics, MTTR, analyzer/DLQ alarms, X-Ray) | ✅ | ⏸️ | Metrics visible on dashboard |
| 9 | Evidence capture, load test, demo video, cleanup | ✅ local evidence | ⏸️ | `docs/evidence/` checklist complete; `terraform destroy` clean |

## Phase-by-phase deployment (when you approve)

1. **Phase 1-2 (≈ $1.45/day):** bootstrap (optional) → build package → `terraform apply` → push image.
2. **Phase 3:** run Scenario B, check the incident record and SNS mail.
3. **Phase 4:** enable model access for the chosen Claude model in the Bedrock console, then set
   `bedrock_enabled = true`. **Verify** the IAM actions the Bedrock endpoint used by
   `AnthropicBedrockMantle` requires in your region and adjust `bedrock_iam_actions` if the first
   call returns `AccessDenied` (the incident still gets a rules-engine analysis, and the rationale
   records the failure).
4. **Phase 5-6:** Scenarios A and C, dashboard screenshots.
5. **Phase 7:** configure GitHub variables + `aws-dev` environment reviewers; run `deploy` (plan).
6. **Phase 9:** load test against the ALB, record the video, `terraform destroy`.

## Planned / not implemented (be explicit in interviews)

- 📋 HTTPS listener + WAF (needs a domain/ACM certificate).
- 📋 Configuration-drift detection (AWS Config rules → same EventBridge path).
- 📋 Cost-anomaly incidents (Cost Anomaly Detection → EventBridge → analyzer category `COST_ANOMALY`).
- 📋 Slack/Teams approval UI in front of the same IAM-authenticated approval endpoint.
- 📋 Multi-account rollout (EventBridge cross-account bus, StackSets/Terragrunt).
- 📋 Evaluation set for the Bedrock prompt (labelled historical incidents, accuracy tracking).
