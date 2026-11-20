# Implementation evidence

Evidence is separated by where it was produced. **Do not mix them up in interviews.**

## A. Local evidence (✅ produced - no AWS account involved)

| Artifact | File | How to regenerate |
|---|---|---|
| Unit/integration test report (60 tests) + coverage (≈93%) | `local/pytest-report.txt`, `local/pytest-junit.xml`, `local/coverage.xml` | `make test` |
| Terraform fmt / validate / offline tests (3 stack + 7 guardrail tests) | `local/terraform-validation.md` | `make tf-validate tf-test` |
| Checkov IaC scan (0 failed) | `local/checkov.md` | `make checkov` |
| Offline end-to-end incident simulation (scenarios A, B, C) | `local/incident-simulation.md` | `make demo-local` |
| Load test of the sample app (single local process) | `local/load-tests/*.md` | `make load-test-local` |

Notes: the local simulation runs the real Lambda code against moto (mocked DynamoDB) with
recorded evidence and the rules engine; it proves the logic, not AWS wiring. The local load test
measures one Python process on a shared CI container (p99 includes connection-setup outliers); it is
a baseline, not a capacity claim.

## B. GitHub Actions evidence (⏳ after you push / run workflows)

- [ ] Screenshot of a green `ci` run (all 4 jobs) → `github/ci-run.png`
- [ ] Downloaded `python-test-reports` artifact → `github/`
- [ ] Checkov SARIF visible in the Security tab → `github/code-scanning.png`
- [ ] `deploy` workflow **plan** run summary → `github/deploy-plan.png`
- [ ] `deploy` **apply** paused for environment approval → `github/deploy-approval.png`

## C. AWS-deployed evidence (⏸️ requires your approval to deploy)

Store screenshots under `aws/` (redact account ids if you prefer).

- [ ] `terraform apply` summary (resources created) → `aws/terraform-apply.txt`
- [ ] App healthy via ALB (`curl /health`) → `aws/app-healthy.png`
- [ ] All alarms OK → `aws/alarms-ok.png`
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
