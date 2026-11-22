# Phased implementation plan

Status legend: ✅ **Done locally** (code + automated tests, no AWS) · 🟢 **Deployed and verified in AWS** ·
⏸️ **Awaiting your approval / not yet exercised in AWS** · 📋 **Planned**.

The first deployment (bootstrap + full dev stack, Bedrock off) is live in `us-east-2`. The step-by-step
record, including every failure and fix, is in [`deployment-log.md`](deployment-log.md).

| Phase | Scope | Local status | AWS status | Exit criteria |
|---|---|---|---|---|
| 0 | ADR, architecture, repo structure, prerequisites, cost & security estimates | ✅ | n/a | Docs reviewed |
| 1 | Monitored sample workload (VPC, ECS Fargate, ALB, ECR, KMS, secret) | ✅ `terraform validate` + mocked `terraform test` | 🟢 `/health` → 200 via ALB from the owner's /32 | `curl $APP_URL/health` → 200 |
| 2 | Alarms (CPU, memory, 5xx, app errors, unhealthy / no healthy targets) + EventBridge routing + DLQ | ✅ | 🟢 8/8 alarms `OK` | Alarms in `OK`; rules show invocations |
| 3 | Incident analyzer (evidence, dedupe, severity, rules engine, DynamoDB, SNS) | ✅ 60 unit/integration tests | 🟢 deployed; ⏸️ Scenario B not yet run | Scenario B creates and auto-resolves an incident |
| 4 | Bedrock-assisted root cause summaries (opt-in) | ✅ tested with a fake client | ⏸️ disabled by decision; needs Bedrock model access | Incident `engine = bedrock:…`; fallback proven by disabling access |
| 5 | Human-approved remediation (4 SSM runbooks, approval Function URL, 2-person rule) | ✅ | 🟢 deployed; ⏸️ Scenarios A and C not yet run | Scenario A restored via approved runbook; Scenario C waits at `aws:approve` |
| 6 | Operations dashboard (custom widget + metrics) | ✅ render tested | 🟢 dashboard live (incident table awaits first incident) | Dashboard screenshot shows incident table |
| 7 | Automated testing + CI/CD (GitHub Actions, OIDC, plan/apply split, image pipeline) | ✅ CI fixed + hardened (SHA-pinned actions); 25 offline Terraform tests | 🟢 bootstrap applied; `image` + approval-gated `deploy` (plan → apply) used for the live stack | Green `ci` on the PR; `deploy` plan run from `main` |
| 8 | Observability of the platform itself (EMF metrics, MTTR, analyzer/DLQ alarms, X-Ray) | ✅ | 🟢 deployed; ⏸️ metrics appear with the first incidents | Metrics visible on dashboard |
| 9 | Evidence capture, load test, demo video, cleanup | ✅ local evidence | ⏸️ | `docs/evidence/` checklist complete; `terraform destroy` clean |

## Next step

Run the incident scenarios against the live stack (B, then A, then C) and capture the evidence listed
in [`evidence/README.md`](evidence/README.md). Windows operators: [`runbooks/windows-powershell.md`](runbooks/windows-powershell.md).

## Phase-by-phase deployment (when you approve)

1. **Phase 1-2 (≈ $1.35/day):** bootstrap (required) → publish image → plan → approval-gated apply (see `deployment-plan.md`).
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
