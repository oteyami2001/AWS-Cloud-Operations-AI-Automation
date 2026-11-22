# Implementation evidence

Evidence is separated by where it was produced. **Do not mix them up in interviews.**

## A. Local evidence (✅ produced - no AWS account involved)

| Artifact | File | How to regenerate |
|---|---|---|
| **All local gates in one run** (lint, SAST, 60 tests, fmt, validate, 25 Terraform tests, tflint, Checkov, Trivy, simulation) | `local/validation-run.txt` | see the commands in that file |
| Unit/integration test report (60 tests) + coverage (≈93%) | `local/pytest-report.txt`, `local/pytest-junit.xml`, `local/coverage.xml` | `make test` |
| Terraform fmt / validate / offline tests (25: bootstrap 6, envs/dev 7, aiops 7, workload 5) | `local/terraform-validation.md` | `make tf-validate tf-test` |
| Checkov IaC scan (406 passed, 0 failed, 38 justified skips) | `local/checkov.md` | `make checkov` |
| Pre-deployment security review (Checkov skip review, ingress, IAM/OIDC, state, budget) | `../security-review.md` | — |
| Offline end-to-end incident simulation (scenarios A, B, C) | `local/incident-simulation.md` | `make demo-local` |
| Load test of the sample app (single local process) | `local/load-tests/*.md` | `make load-test-local` |

Notes: the local simulation runs the real Lambda code against moto (mocked DynamoDB) with
recorded evidence and the rules engine; it proves the logic, not AWS wiring. The local load test
measures one Python process on a shared CI container (p99 includes connection-setup outliers); it is
a baseline, not a capacity claim.

## B. GitHub Actions evidence (✅ workflows have run; save screenshots to `github/`)

- [x] Screenshot of a green `ci` run (all 4 jobs) on the PR → `github/ci-run.png`
- [x] `image` workflow run (Trivy gate + pushed digest) → `github/image-run.png`
- [ ] Downloaded `python-test-reports` artifact → `github/`
- [ ] Checkov SARIF visible in the Security tab → `github/code-scanning.png`
- [x] `deploy` workflow **plan** run summary (`81 to add`, run #5) → `github/deploy-plan.png`
- [x] `deploy` **apply** paused for environment approval (runs #9, #10) → `github/deploy-approval.png`

## C. AWS-deployed evidence (🟢 stack deployed; ⏸️ scenarios not yet run)

Store screenshots under `aws/`. A ticked box means the result was observed; add the screenshot file to complete it.
Redact your public IP, e-mail and load balancer DNS name before committing screenshots.

- [x] `terraform apply` summary (resources created; see [`../deployment-log.md`](../deployment-log.md)) → `aws/terraform-apply.txt`
- [x] App healthy via ALB (`curl /health` → `{"status": "ok"}`) → `aws/app-healthy.png`
- [x] All alarms OK (8/8) → `aws/alarms-ok.png`
- [ ] Scenario A: `no-healthy-targets` ALARM → `aws/scenarioA-alarm.png`
- [ ] Scenario A: SNS e-mail with summary + recommendation → `aws/scenarioA-sns.png`
- [ ] Scenario A: `approve.py --show` output → `aws/scenarioA-show.txt`
- [ ] Scenario A: approval response + SSM execution succeeded → `aws/scenarioA-ssm.png`
- [ ] Scenario A: incident `RESOLVED` with history on the dashboard → `aws/scenarioA-dashboard.png`
- [ ] Scenario B: auto-resolved incident (self-healed) → `aws/scenarioB-dashboard.png`
- [ ] Scenario C: SSM execution waiting at `SecondApproval` → `aws/scenarioC-waiting.png`
- [ ] Bedrock-generated analysis (`engine = bedrock:…`) → `aws/bedrock-analysis.png`
- [ ] Bedrock fallback (access removed → `engine = rules` + rationale) → `aws/bedrock-fallback.png`
- [ ] Load test against the ALB + CPU alarm / dashboard during the test → `load-tests/alb-*.md`, `aws/load-test-dashboard.png`
- [ ] CloudTrail event showing `StartAutomationExecution` by the approval role → `aws/cloudtrail.png`
- [ ] `terraform destroy` complete + tag query empty → `aws/cleanup.txt`
- [ ] Demo video (≈ 6 min, script in `docs/demo-scenario.md`) → link here: _TBD_
