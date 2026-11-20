# Cleanup procedure

Run this at the end of every demo session. It removes every billable resource the project creates.

## 1. Destroy the dev environment

```bash
terraform -chdir=terraform/envs/dev destroy
```

The configuration is built to destroy cleanly: ECR `force_delete = true` (images removed), the
Secrets Manager secret has `recovery_window_in_days = 0`, ALB and DynamoDB have no deletion
protection, and the KMS key is scheduled for deletion with a 7-day window (no charge after the
scheduled deletion completes; **cancel** it within 7 days if you need to restore anything).

## 2. Check for leftovers

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=aiops --query 'ResourceTagMappingList[].ResourceARN'
```

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/aiops-dev --query 'logGroups[].logGroupName'
```

Expected: empty lists (the KMS key may still show as `PendingDeletion`, which is fine).
If an SSM Automation execution is still waiting at `aws:approve`, cancel it:

```bash
aws ssm describe-automation-executions --filters Key=ExecutionStatus,Values=Waiting --query 'AutomationExecutionMetadataList[].AutomationExecutionId'
```

```bash
aws ssm stop-automation-execution --automation-execution-id <id>
```

## 3. (Optional) remove the bootstrap stack

Only if you no longer need CI access or remote state. Empty the versioned state bucket first
(console: *Empty bucket*), then:

```bash
terraform -chdir=terraform/bootstrap destroy
```

## 4. Other

- Unsubscribe / delete the SNS confirmation e-mail subscription if it lingers.
- The AWS Budget is deleted with the environment; keep an account-level budget anyway.
- Remove the local `build/` directory and `terraform.tfvars` if you are sharing the machine.
