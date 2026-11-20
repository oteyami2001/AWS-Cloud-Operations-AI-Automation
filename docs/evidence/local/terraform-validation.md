# Terraform validation - LOCAL (offline, mocked providers; nothing deployed)

Generated 2026-11-20T15:59:10Z with Terraform v1.9.8

## terraform fmt -check -recursive
```
OK - all files formatted
```
## terraform validate (envs/dev)
```
Success! The configuration is valid.

```
## terraform validate (bootstrap)
```
Success! The configuration is valid.

```
## terraform test (envs/dev - full stack, mocked apply)
```
tests/plan.tftest.hcl... in progress
  run "full_stack_mock_apply"... pass
  run "bedrock_off_by_default"... pass
  run "ingress_must_be_explicit"... pass
tests/plan.tftest.hcl... tearing down
tests/plan.tftest.hcl... pass

Success! 3 passed, 0 failed.
```
## terraform test (modules/aiops - security guardrails)
```
tests/guardrails.tftest.hcl... in progress
  run "approval_endpoint_requires_iam_auth"... pass
  run "analyzer_cannot_change_infrastructure"... pass
  run "only_remediation_function_starts_automation"... pass
  run "bedrock_permission_only_when_enabled"... pass
  run "bedrock_permission_when_enabled"... pass
  run "encryption_and_cost_caps"... pass
  run "human_roles_require_mfa_by_default"... pass
tests/guardrails.tftest.hcl... tearing down
tests/guardrails.tftest.hcl... pass

Success! 7 passed, 0 failed.
```
