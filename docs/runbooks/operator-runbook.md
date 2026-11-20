# Operator runbook - responding to an AIOps incident

## 1. You receive an SNS notification

It contains: incident id, severity, AI/rules summary, probable cause, the recommended runbook, its
risk, and the exact approve command. **Nothing has been changed yet.**

| Severity | Meaning | Target response |
|---|---|---|
| SEV1 | Customer-facing outage (e.g. no healthy targets) | Acknowledge within 5 min |
| SEV2 | Major degradation (5xx spike, unhealthy targets) | 15 min |
| SEV3 | Early warning (CPU/memory high, task stopped) | Business hours |
| SEV4 | Unclassified | Triage queue |

## 2. Review the evidence

```bash
AWS_PROFILE=aiops-operator python scripts/approve.py --incident <INC-id> --show
```

Also check the dashboard (incident table, target health, recent errors). Ask:

- Does the evidence support the probable cause? Check the `engine` and `confidence` fields; an
  `engine = rules` with a rationale mentioning Bedrock means the AI step failed or was skipped.
- Is the recommended runbook the **least invasive** fix? Restart < restore count < scale out < rollback.
- Is something else already changing the service (deployment in progress, another operator)?

## 3. Decide

Approve (starts the SSM runbook; your IAM identity is recorded):

```bash
AWS_PROFILE=aiops-operator python scripts/approve.py --incident <INC-id> --decision approve --justification "<why>"
```

Approve a different, still-approved runbook for that category:

```bash
AWS_PROFILE=aiops-operator python scripts/approve.py --incident <INC-id> --decision approve --runbook restart-ecs-service --justification "<why>"
```

Reject (incident stays tracked; you can approve later):

```bash
AWS_PROFILE=aiops-operator python scripts/approve.py --incident <INC-id> --decision reject --justification "<why>"
```

## 4. HIGH-risk runbooks (rollback) need a second person

The SSM execution pauses at `SecondApproval`. A **different** person using the senior-approver role:

```bash
AWS_PROFILE=aiops-senior-approver aws ssm send-automation-signal --automation-execution-id <exec-id> --signal-type Approve --payload Comment="<why>"
```

## 5. Confirm resolution

The incident becomes `RESOLVED` when the runbook succeeds or the alarm returns to `OK`; time to
recover is recorded as the `AIOps/TimeToRecoverSeconds` metric. If it becomes
`REMEDIATION_FAILED`, inspect the execution, then retry or escalate:

```bash
aws ssm get-automation-execution --automation-execution-id <exec-id> --query 'AutomationExecution.StepExecutions[].[StepName,StepStatus,FailureMessage]' --output table
```

## Approved runbook catalog

| Runbook id | SSM document | Risk | Used for | What it does |
|---|---|---|---|---|
| `restart-ecs-service` | `<prefix>-RestartEcsService` | MEDIUM | unhealthy targets, task stopped, memory | Force new deployment, wait for steady state |
| `restore-ecs-desired-count` | `<prefix>-RestoreEcsDesiredCount` | MEDIUM | no healthy targets | Desired count → baseline (1-2 allowed) |
| `scale-out-ecs-service` | `<prefix>-ScaleOutEcsService` | MEDIUM | CPU / memory | Desired count → max (2-4 allowed) |
| `rollback-ecs-task-definition` | `<prefix>-RollbackEcsTaskDefinition` | HIGH | 5xx / app errors, task stopped | 2nd approval, then previous task-definition revision |

Adding a runbook = new SSM document + catalog entry in `src/aiops/runbooks.py` + tests + code review.
The AI cannot add or modify runbooks.

## Platform alarms (page directly)

- `<prefix>-platform-analyzer-errors` - the analyzer is failing; incidents may be missing. Check
  `/aws/lambda/<prefix>-incident-analyzer` logs.
- `<prefix>-platform-dlq-not-empty` - events failed delivery. Inspect and redrive the SQS DLQ.
