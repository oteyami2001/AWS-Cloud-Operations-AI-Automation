# Interview talking points

Use these honestly: say what was tested locally, what ran in AWS, and what is planned.

## 60-second pitch

"I built an event-driven AIOps platform on AWS. CloudWatch alarms and ECS task events flow through
EventBridge into a Python Lambda that deduplicates, collects evidence - ECS service state, stopped
task exit codes, target health, recent error logs, metrics - classifies severity deterministically,
and asks Claude on Amazon Bedrock for a root-cause summary. The model's answer is constrained to a
JSON schema whose recommended action must be one of four pre-approved SSM Automation runbooks, and
if Bedrock fails or refuses, a rules engine takes over. Nothing executes without a human: operators
approve through an IAM-authenticated endpoint, and the riskiest runbook needs a second approver
enforced natively by SSM. Everything is Terraform with offline tests in GitHub Actions."

## Design decisions to discuss

1. **Why AI only recommends** - blast radius; LLMs can be confidently wrong or prompt-injected via
   log lines. The structural guarantee is IAM (analyzer has no write permissions) plus a schema enum,
   not prompt wording. Tests prove both.
2. **Deterministic severity** - paging must be predictable and auditable; the model explains, rules decide.
3. **Graceful degradation** - rules engine fallback on errors, refusals, malformed output, and a
   daily Bedrock quota enforced atomically in DynamoDB (cost control during alarm storms; plus
   reserved concurrency).
4. **Deduplication & correlation** - one incident per dedupe key; a task stop caused by an open
   unhealthy-targets incident is attached to it instead of paging twice.
5. **Approval identity** - taken from the SigV4-verified caller ARN, not from the request body
   (there's a test that tries to spoof it).
6. **Two-person rule** - `aws:approve` inside the SSM document, so even a bug in my Lambda cannot
   skip the second approval.
7. **Bounded runbooks** - `allowedPattern`/`allowedValues` on SSM parameters; automation role scoped
   to one ECS service ARN.
8. **Cost** - no NAT, one small Fargate task, ~$1.45/day, budget alerts, destroy after demos.
9. **Testing strategy** - pytest + moto for logic; `terraform test` with mocked providers asserts
   IAM guardrails in CI without AWS credentials; checkov/tflint/bandit/Trivy for security.
10. **Trade-offs I'd change for production** - HTTPS + WAF, private subnets + VPC endpoints, longer
    log retention, multi-account event bus, Slack approval UX, prompt evaluation set.

## Capital One Cloud Engineer-style mapping

| Responsibility | Evidence in this repo |
|---|---|
| Design/build cloud infrastructure with IaC | 7 Terraform modules, bootstrap, environment composition |
| Operational excellence / incident response | Alarms, incident lifecycle, MTTR metric, operator runbook |
| Automation | EventBridge → Lambda → SSM pipeline, CI/CD |
| Security & compliance | Least-privilege IAM, KMS everywhere, OIDC, MFA, two-person rule, checkov |
| Cost management | Budget, tags, quota, no-NAT design, cleanup procedure |
| Observability | EMF metrics, dashboard, X-Ray, self-monitoring alarms, DLQ |
| AI/ML integration with guardrails | Bedrock with schema-constrained output and fallback |

## Likely questions

- *What if the model recommends the wrong runbook?* The human reviews evidence first; the runbook
  must still be approved for that incident category; HIGH risk needs a second person; all runbooks
  are bounded and reversible.
- *What if EventBridge delivery fails?* Retries (4, up to 1 h) then SQS DLQ with an alarm.
- *How do you prevent alert storms?* Dedupe key per category+service, correlation, reserved
  concurrency, Bedrock quota.
- *How do you test IAM?* `terraform test` asserts policy statements (e.g. no `ssm:` actions in the
  analyzer policy) from the plan, offline.
