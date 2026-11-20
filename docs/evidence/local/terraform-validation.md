# Terraform validation - LOCAL (offline, mocked providers; nothing deployed)

Generated 2026-11-20T22:24:26Z with Terraform v1.17.2, AWS provider 5.100.0

```
terraform fmt: OK
bootstrap: Success! The configuration is valid.
envs/dev: Success! The configuration is valid.
modules/aiops: Success! The configuration is valid.
modules/workload: Success! The configuration is valid.
== bootstrap
  run "oidc_trust_is_exact_and_audience_bound"... pass
  run "apply_role_cannot_escalate"... pass
  run "plan_role_is_describe_only"... pass
  run "state_bucket_is_private_versioned_encrypted"... pass
  run "budget_alerts_configured"... pass
  run "budget_email_required"... pass
Success! 6 passed, 0 failed.
== envs/dev
  run "full_stack_mock_apply"... pass
  run "bedrock_off_by_default"... pass
  run "image_is_pinned_by_digest"... pass
  run "ingress_must_be_explicit"... pass
  run "ingress_rejects_open_internet"... pass
  run "ingress_rejects_ranges_wider_than_32"... pass
  run "ingress_rejects_malformed_address"... pass
Success! 7 passed, 0 failed.
== modules/aiops
  run "approval_endpoint_requires_iam_auth"... pass
  run "analyzer_cannot_change_infrastructure"... pass
  run "only_remediation_function_starts_automation"... pass
  run "bedrock_permission_only_when_enabled"... pass
  run "bedrock_permission_when_enabled"... pass
  run "encryption_and_cost_caps"... pass
  run "human_roles_require_mfa_by_default"... pass
Success! 7 passed, 0 failed.
== modules/workload
  run "alb_ingress_is_exactly_the_operator_ip_on_port_80"... pass
  run "tasks_accept_traffic_only_from_the_alb"... pass
  run "no_public_admin_surfaces"... pass
  run "roles_carry_permissions_boundary"... pass
  run "wide_ingress_rejected_at_module_level"... pass
Success! 5 passed, 0 failed.
```
