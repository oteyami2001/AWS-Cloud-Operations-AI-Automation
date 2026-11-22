# First AWS deployment: what happened

This is the record of the first real deployment of the platform to AWS: every step, every failure,
its root cause and the fix that went into the code. It is written as an operations log: facts that
were observed, not plans.

- **Account / region:** dev account, `us-east-2` (see [ADR 0003](adr/0003-region-us-east-2.md))
- **Deployed from:** `main`, through the approval-gated `deploy` workflow (no local `terraform apply` of the workload)
- **Result:** 18 bootstrap resources + 81 workload resources, app healthy, 8/8 alarms `OK`

Values that identify the owner (public IP, alert e-mail, load balancer DNS name) are left out on purpose.

## Timeline

| # | Step | Outcome | Root cause | Fix |
|---|---|---|---|---|
| 1 | Bootstrap in `us-east-1` (admin, local) | ❌ stopped after 6 of 18 resources | The AWS Organization SCP explicitly denies regional services in `us-east-1` (`s3:CreateBucket` denied) | Tested which regions the SCP allows; owner approved `us-east-2` ([ADR 0003](adr/0003-region-us-east-2.md), PR #5) |
| 2 | Bootstrap resumed in `us-east-2` with `scripts/bootstrap_resume.sh` | ✅ 18 resources; state migrated to the encrypted, versioned S3 bucket with native lock file | The resume script first stopped on Terraform's "will be read during apply" lines | Script only rejects real updates/destroys (PR #4) |
| 3 | First `image` and `deploy` workflow runs | ❌ `AssumeRoleWithWebIdentity` denied | The repository uses GitHub's **immutable OIDC subject** format (`repo:owner@id/repo@id:...`), not `repo:owner/repo:...` | Trust policies built from owner/repository IDs; 3 in-place trust updates (PR #6) |
| 4 | `image` workflow | ✅ `aiops-sample-app:v1` pushed after the Trivy gate | Trivy had blocked earlier images with OS CVEs | Dockerfile hardening (apt upgrade, pip removed, non-root uid 10001) |
| 5 | `deploy` #2 (plan) | ⚠️ **green, but the plan had failed** | `terraform plan \| tee` ran without `pipefail`, so the pipeline returned `tee`'s exit code | `defaults.run.shell: bash` (PR #7). Lesson: read the plan summary, not just the green tick |
| 6 | `deploy` #3–#4 (plan) | ❌ two real errors surfaced | (a) the `ALERT_EMAIL` variable had a trailing space; (b) the read-only plan role lacked `secretsmanager:GetRandomPassword`, needed to open the ephemeral fault-token password | Root module trims the e-mail; region-scoped `GetRandomPassword` on the plan role (PR #8) |
| 7 | `deploy` #5 (plan) | ✅ `Plan: 81 to add, 0 to change, 0 to destroy`, reviewed resource by resource | — | — |
| 8 | `deploy` #6–#8 | ✅ plan only, apply job **skipped** | The `action` input defaults to `plan`; the run form shows its description ("plan, apply or destroy"), not its name | Operator note below |
| 9 | `deploy` #9 (apply, approved in `aws-dev`) | ❌ 80 of 81 created; `PutDashboard` → 400 | `flatten()` in the Lambda widget also flattened each metric row into loose strings ("Should be array" ×32) | `setproduct()` rows + a `precondition` so `terraform test` fails on a malformed dashboard offline (PR #9) |
| 10 | `deploy` #10 (apply, approved) | ✅ `1 added, 4 changed, 0 destroyed` | The 4 "changed" are Lambda code re-uploads: the zip is rebuilt on each run with new timestamps, so its hash differs (same code) | Known, harmless; tracked below |

## Verified after deployment

| Check | How | Result |
|---|---|---|
| App reachable only from the owner's IP | `curl.exe http://<app_url>/health` from the allowed /32 | `{"status": "ok"}` |
| Alarms | CloudWatch → Alarms | 8/8 `OK` (6 workload + 2 platform), 0 in alarm, 0 insufficient data |
| Alert delivery | SNS e-mail subscription | Confirmed by the owner |
| Operations dashboard | `dashboard_url` output | Renders; the custom incident widget runs only after the console's "Allow" prompt for `aiops-dev-dashboard-widget` (read-only Lambda) |
| Image provenance | Task definition | Pinned to the ECR **digest**, not the tag |
| Ingress | Plan review + output `alb_allowed_ingress_cidrs` | Single /32; the only `0.0.0.0/0` entries are the default route and task egress on 443 |
| Bedrock | Variable `bedrock_enabled` | `false` (rules engine only, as decided for the first deployment) |

## Scenario B: unhealthy task (run on 2026-11-22, Windows PowerShell)

Fault injected with `POST /fault/unhealthy` (token from Secrets Manager), from the owner's allowed IP.

| Time (UTC) | Observed |
|---|---|
| ~07:31 | `/health` returns 503 and the app logs `ERROR health check failing ...` on every health check |
| 07:33:37 | `aiops-dev-app-errors` → ALARM (AppErrorCount > 5). Incident **`INC-20261122-90e9b024`, SEV2 `APPLICATION_ERRORS`** opened; SNS e-mail sent with summary, probable cause and recommendation `rollback-ecs-task-definition` (risk HIGH) |
| ~07:34 | The load balancer marked the task unhealthy; **ECS replaced it by itself** (the new task starts without the fault) |
| ~07:35 | Alarm back to OK; incident **auto-RESOLVED** (`RECOVERED`, by `system`); "RESOLVED" e-mail with **MTTR 118 s** |

**What matched the design:** detection → incident → e-mail → dashboard → self-healing → auto-resolution, with no
human action. The HIGH-risk rollback the rules engine recommended was **never executed**: remediation only runs
after an explicit approval, and none was given.

**What differed from the prediction (and why):**
- The expected `unhealthy-targets` alarm did **not** fire. `UnHealthyHostCount` was 1 for a single minute,
  because ECS replaced the task faster than the alarm's "2 datapoints within 2 minutes" window. The alarm
  history shows only `Insufficient data → OK`.
- The incident was classified **`APPLICATION_ERRORS`**, not an unhealthy-target incident, because the fault
  also writes `ERROR` log lines, which drive the `app-errors` metric alarm. The classification follows the alarm
  that fired; the recommendation (rollback, HIGH) was reasonable for that signal, but a human reviewing it
  would see the evidence and the fact that it had already recovered.

**Also visible on the dashboard:** a SEV1 `NO_HEALTHY_TARGETS` incident (`INC-20261122-91e4ad15`) at
05:00:58 UTC, during the first apply, while the very first task was still starting. It auto-resolved as soon as
the task became healthy. It is a deployment-time false positive (see follow-ups).

Evidence: [`evidence/aws/scenarioB-sns-incident.png`](evidence/aws/scenarioB-sns-incident.png),
[`scenarioB-sns-resolved.png`](evidence/aws/scenarioB-sns-resolved.png),
[`scenarioB-alarms.png`](evidence/aws/scenarioB-alarms.png).

## Guardrails that held

- **Approval gate:** the apply job runs only after the owner approves the `aws-dev` environment, and it applies the exact plan file that was reviewed.
- **No long-lived keys:** CI uses GitHub OIDC; the plan role is read-only, the apply role trusts only the `aws-dev` environment and can create IAM roles only with the workload permissions boundary.
- **Partial failure was safe:** when apply #9 failed, the 80 created resources stayed in remote state, and the next apply added only the missing dashboard. Nothing was recreated.
- **Every failure became a test:** pipefail, e-mail trimming, `GetRandomPassword` and the dashboard shape are covered by `terraform test` or CI, so they are caught before an apply next time.

## Operator notes

**Starting an apply.** Actions → `deploy` → **Run workflow** → in the field **"plan, apply or destroy"**
pick `apply` → Run. The first job must be named `terraform plan (apply)`. When the run shows
**Review deployments**, check the plan summary, then approve `aws-dev`.

**Daily cost.** About $1.35/day while deployed. Tear down with the same workflow and `destroy`
([`cleanup.md`](cleanup.md)); the bootstrap (state, OIDC roles, ECR, budget) stays.

**Windows operators.** The helper scripts are bash. PowerShell equivalents are in
[`runbooks/windows-powershell.md`](runbooks/windows-powershell.md).

## Open follow-ups

- 📋 Make the Lambda zip reproducible (fixed timestamps and file order) so a no-change deploy shows `0 to change`.
- 📋 Correlate health-check failures logged as `ERROR` with the target-health signal, so a failing `/health` is classified as an unhealthy-target incident rather than generic application errors.
- 📋 Suppress `NO_HEALTHY_TARGETS` incidents while an ECS deployment is in progress (or delay the alarm until the service has reached steady state once).
- ✅ Scenario B run (above). 📋 Scenarios A and C against the deployed stack ([`demo-scenario.md`](demo-scenario.md)); evidence goes to [`evidence/README.md`](evidence/README.md).
- 📋 Bedrock (Phase 4) remains disabled until the owner approves it.
