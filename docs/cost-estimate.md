# Cost estimate (us-east-1)

The detailed, line-item estimate, including minimum billable periods and persistent charges, is in
**[`deployment-plan.md` → Cost estimate](deployment-plan.md#cost-estimate-us-east-1-on-demand-list-prices-verify-with-the-aws-pricing-calculator)**.
These are estimates from public on-demand list prices; verify them with the [AWS Pricing Calculator](https://calculator.aws/).

| Scenario | Estimate |
|---|---|
| `envs/dev` running (Phases 1–2 apply, Bedrock off) | ≈ $0.058/hour · ≈ $1.30–1.40/day · ≈ $38–43/month |
| One demo session (deploy, scenarios, evidence, destroy in under 3 h) | ≈ $0.20–0.35 |
| Shortest possible run (apply then destroy) | ≈ $0.06 (ALB and public IPv4 bill per started hour) |
| Bootstrap left in place (state bucket, ECR image, IAM/OIDC, budget) | ≈ $0.01/month |
| Bedrock (Phase 4, not enabled) | $0 now. Later: one call per new incident, capped by `bedrock_daily_call_limit` (default 20/day) |

## Cost controls built in

- Account-wide AWS Budget (bootstrap, $30/month default) with e-mail at 50/80/100 % actual and
  100 % forecast. It exists before any deployment and survives `destroy`. Alerts lag actual spend by hours.
- Default tags (`Project`, `Environment`, `Owner`, `CostCenter`) on every resource.
- No NAT gateway (saves ≈ $33/month), and no Container Insights, flow logs, ALB access logs or WAF by default.
- One 0.25 vCPU Fargate task; remediation runbooks cap the desired count with `allowedValues` (max 4).
- 14-day log retention, ECR lifecycle (keep 10 images), on-demand DynamoDB, reserved Lambda concurrency.
- Bedrock off by default, with an atomic daily call cap in DynamoDB when enabled.
