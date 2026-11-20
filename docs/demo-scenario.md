# Demonstration script (≈ 6-minute video)

Run against the deployed dev environment. Before recording: deploy, confirm alarms are `OK`, open
the dashboard and a terminal side by side.

| # | Time | Show | Command / action | Expected result |
|---|---|---|---|---|
| 1 | 0:00 | Architecture diagram (README) | - | 20-second walkthrough of detect → analyse → approve → remediate |
| 2 | 0:30 | Healthy app + dashboard | `curl $APP_URL/health` | `{"status":"ok"}`, all alarms OK |
| 3 | 1:00 | **Scenario A - stop the application** | `scripts/simulate_incident.sh stop` | Desired count 0 |
| 4 | 1:00-3:00 | Alarm fires | dashboard | `no-healthy-targets` → ALARM; SNS mail; incident `SEV1 NO_HEALTHY_TARGETS` with probable cause "desired count is 0" and recommendation `restore-ecs-desired-count` |
| 5 | 3:00 | Human review | `approve.py --show` | Evidence, engine (bedrock or rules), steps |
| 6 | 3:30 | Human approval | `approve.py --decision approve --justification ...` | 200, execution id, status `REMEDIATING` |
| 7 | 3:45 | SSM console | Automation execution | Steps `SetDesiredCount`, `WaitForRunningTasks` succeed |
| 8 | 4:30 | Resolution | dashboard | Incident `RESOLVED`, history shows approver ARN, MTTR metric |
| 9 | 5:00 | **Scenario C - HIGH risk** | `simulate_incident.sh errors` (pre-recorded is fine) → approve | SSM execution **Waiting** at `SecondApproval` until senior approver signals |
| 10 | 5:40 | Safety recap | `tests/unit/test_ai.py`, `terraform test` output | AI cannot pick unapproved actions; analyzer has no SSM rights |

**Scenario B (optional, unhealthy task):** `simulate_incident.sh unhealthy` → `unhealthy-targets`
ALARM → incident opened → ECS replaces the failing task by itself → alarm OK → incident
auto-`RESOLVED` with no human action (shows the platform also documents self-healing).

Reset after each scenario: `scripts/simulate_incident.sh reset` (and for A, the approved runbook
restores the desired count).
