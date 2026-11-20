# Cleanup procedure

Run this at the end of every demo session to stop all hourly charges.

## 1. Destroy the dev environment

Use GitHub *Actions → deploy → Run workflow* with `action = destroy`, then approve in `aws-dev`. Or locally (SSO credentials):

```bash
terraform -chdir=terraform/envs/dev destroy -var='allowed_ingress_cidrs=["<your-ip>/32"]'
```

The environment is built to destroy cleanly:

- The Secrets Manager secret has `recovery_window_in_days = 0`.
- The ALB and DynamoDB have no deletion protection.
- The KMS key is scheduled for deletion with a 7-day waiting period. You can **cancel** that within the 7 days if you need to restore anything.

## 2. Check for leftovers

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=aiops Key=Environment,Values=dev --query 'ResourceTagMappingList[].ResourceARN'
```

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/aiops-dev --query 'logGroups[].logGroupName'
```

Expected: empty lists; a KMS key in `PendingDeletion` is fine. If an SSM Automation execution is still waiting at `aws:approve`, list it:

```bash
aws ssm describe-automation-executions --filters Key=ExecutionStatus,Values=Waiting --query 'AutomationExecutionMetadataList[].AutomationExecutionId'
```

Then stop it:

```bash
aws ssm stop-automation-execution --automation-execution-id <id>
```

## 3. (Optional) remove the bootstrap stack

Bootstrap costs about $0.01/month, so only remove it when the project is finished. Removing it
deletes CI access, remote state, the ECR repository and the budget. First move the bootstrap state
back to local:

```bash
mv terraform/bootstrap/backend.tf terraform/bootstrap/backend.tf.disabled
```

```bash
terraform -chdir=terraform/bootstrap init -migrate-state
```

Empty the versioned state bucket (console: *S3 → bucket → Empty*), then:

```bash
terraform -chdir=terraform/bootstrap destroy
```

## 4. Other

- Delete the SNS confirmation subscription if it remains.
- Remove local `build/` and `terraform.tfvars` files if you share the machine.
