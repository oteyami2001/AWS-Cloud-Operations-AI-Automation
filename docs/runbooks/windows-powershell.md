# Running the incident scenarios from Windows PowerShell

`scripts/simulate_incident.sh` is a bash script that reads its settings from `terraform output`.
On Windows, without a local Terraform checkout of the remote state, use the commands below instead.
They do exactly the same thing.

**Prerequisites:** AWS CLI v2 signed in (`aws login --profile aiops-dev`), and the outputs of the
last successful `deploy` apply run (bottom of the `terraform apply` job log).

## 1. Set the session variables

Replace the values with the outputs of your apply run:

```powershell
$env:AWS_PROFILE = "aiops-dev"
$env:AWS_REGION  = "us-east-2"
$App     = "http://<app_url output>"
$Cluster = "aiops-dev-cluster"
$Service = "aiops-dev-app"
$Table   = "aiops-dev-incidents"
```

Read the fault-injection token into a variable. It is never printed:

```powershell
$Token = aws secretsmanager get-secret-value --secret-id aiops-dev/sample-app/fault-token --query SecretString --output text
```

Check the app first:

```powershell
curl.exe "$App/health"
```

In PowerShell, `curl` is an alias for `Invoke-WebRequest`. Use `curl.exe` or `Invoke-RestMethod`.

## 2. Scenarios

### B: unhealthy task (self-healing, no remediation)

```powershell
Invoke-RestMethod -Method Post -Uri "$App/fault/unhealthy" -Headers @{ "X-Fault-Token" = $Token }
```

Expect `aiops-dev-unhealthy-targets` → ALARM in about 2–3 minutes, an SNS e-mail, and a new incident.
ECS replaces the failing task by itself (the new task starts without the fault), so the alarm returns to OK
and the incident resolves automatically.

### C: 5xx spike (HIGH risk, two approvals)

```powershell
Invoke-RestMethod -Method Post -Uri "$App/fault/errors" -Headers @{ "X-Fault-Token" = $Token }
$end = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $end) { curl.exe -s -o NUL "$App/"; Start-Sleep -Seconds 1 }
```

The traffic loop gives the `alb-5xx` and `app-errors` alarms datapoints.

### A: application stopped (SEV1, restore requires approval)

```powershell
aws ecs update-service --cluster $Cluster --service $Service --desired-count 0 --query service.desiredCount --output text
```

Expect `aiops-dev-no-healthy-targets` → ALARM. The service is restored **only** by the approved
`restore-ecs-desired-count` runbook (section 3), not by `reset`.

### Reset the injected faults

```powershell
Invoke-RestMethod -Method Post -Uri "$App/fault/reset" -Headers @{ "X-Fault-Token" = $Token }
```

### Status: alarms and latest incidents

```powershell
aws cloudwatch describe-alarms --alarm-name-prefix aiops-dev- --query "MetricAlarms[].[AlarmName,StateValue]" --output table
```

```powershell
aws dynamodb scan --table-name $Table --query "Items[].[incident_id.S, severity.S, status.S, title.S]" --output table
```

## 3. Review and approve a remediation (human in the loop)

`scripts/approve.py` works on Windows when you pass `--table` and `--url`, so it doesn't need
Terraform. Run it with the **operator** profile (it assumes the operator role, with MFA; see
[`../deployment.md`](../deployment.md)):

```powershell
pip install boto3
$env:AWS_PROFILE = "aiops-operator"
```

```powershell
python scripts/approve.py --incident <INC-id> --table aiops-dev-incidents --show
```

```powershell
python scripts/approve.py --incident <INC-id> --url "<remediation_url output>" --decision approve --justification "Service scaled to 0 by mistake; restoring baseline."
```

HIGH-risk runbooks (scenario C) then wait at `SecondApproval` until a **different** person, using the
`aiops-senior-approver` profile, approves them.

## 4. End of the session

Reset the faults, then run the `deploy` workflow with **`destroy`** to stop the daily cost.
